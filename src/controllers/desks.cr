# Desks, the bookable desk assets on each level: find free ones, or the ones nearest a desk or a colleague
class Desks < Application
  include Utils::SearchPagination

  base "/api/staff/v1/desks"

  # the most desks returned by desks_nearby
  MAX_RESULTS = 100

  # desks are assets of this type, in a category of the same name, as the workplace apps create them
  DESK_TYPE_NAME = "_DESKS_"

  # a desk asset
  struct Desk
    include JSON::Serializable

    # the asset id, book it with this as the asset_id
    getter id : String
    getter name : String
    # the desk's element on the level map
    getter map_id : String
    # the level the desk is on
    getter zone_id : String?
    getter features : Array(String)
    getter? accessible : Bool
    # the person the desk is assigned to
    getter assigned_to : String?
    # straight line distance from the origin desk, in level map units
    getter distance : Float64?

    def initialize(asset : ::PlaceOS::Model::Asset, @distance = nil)
      @id = asset.id.to_s
      @name = Desks.name_of(asset)
      @map_id = Desks.map_id_of(asset)
      @zone_id = asset.zone_id
      @features = asset.features
      @accessible = asset.accessible
      @assigned_to = asset.assigned_to.presence
    end
  end

  # the level the desks are on
  struct Level
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?
    getter parent_id : String?

    def initialize(zone : ::PlaceOS::Model::Zone)
      @id = zone.id.as(String)
      @name = zone.name
      @display_name = zone.display_name.presence
      @parent_id = zone.parent_id.presence
    end
  end

  # one of the signed in user's desk bookings
  struct YourBooking
    include JSON::Serializable

    getter id : Int64
    getter asset_id : String
    getter title : String?
    getter zones : Array(String)
    getter booking_start : Int64
    getter booking_end : Int64
    getter timezone : String?

    def initialize(booking : Booking)
      @id = booking.id.as(Int64)
      @asset_id = booking.asset_id
      @title = booking.title.presence
      @zones = booking.zones || [] of String
      @booking_start = booking.booking_start
      @booking_end = booking.booking_end
      @timezone = booking.timezone.presence
    end
  end

  # the free desks on a level
  struct FreeDesks
    include JSON::Serializable

    getter level : Level
    getter timezone : String
    getter period_start : Int64
    getter period_end : Int64
    # the features of the free desks, to filter by
    getter features : Array(String)
    # the number of free desks, the desks are paginated
    getter total : Int32
    getter desks : Array(Desk)
    # the signed in user's desk bookings in the period, anywhere in the organisation
    getter your_bookings : Array(YourBooking)

    def initialize(@level, @timezone, @period_start, @period_end, @features, @total, @desks, @your_bookings)
    end
  end

  # the free desks closest to the origin desk
  struct NearbyDesks
    include JSON::Serializable

    getter origin : Desk
    # who the origin desk is booked by, when searching near a colleague
    getter seated : String?
    getter level : Level
    getter timezone : String
    getter period_start : Int64
    getter period_end : Int64
    # free desks, nearest first
    getter desks : Array(Desk)

    def initialize(@origin, @seated, @level, @timezone, @period_start, @period_end, @desks)
    end
  end

  # a colleague and the desk they've booked
  struct Colleague
    include JSON::Serializable

    getter email : String
    getter name : String?
    getter desk : Desk
    getter booking_start : Int64
    getter booking_end : Int64

    def initialize(@email, @name, @desk, booking : Booking)
      @booking_start = booking.booking_start
      @booking_end = booking.booking_end
    end
  end

  # the colleagues sitting on a level and the free desks near them
  struct ColleagueLevel
    include JSON::Serializable

    getter level : Level
    getter timezone : String
    getter colleagues : Array(Colleague)
    # free desks, best first: ranked by every colleague, so a desk near most of them wins.
    # The distance is the average distance to the colleagues, in level map units
    getter desks : Array(Desk)

    def initialize(@level, @timezone, @colleagues, @desks)
    end
  end

  # where colleagues are sitting and the free desks near them
  struct NearColleagues
    include JSON::Serializable

    getter period_start : Int64
    getter period_end : Int64
    # levels with the most colleagues first
    getter levels : Array(ColleagueLevel)
    # colleagues who haven't booked a desk in the period
    getter not_seated : Array(String)
    # colleagues whose desk couldn't be placed on a level map
    getter unranked : Array(String)

    def initialize(@period_start, @period_end, @levels, @not_seated, @unranked)
    end
  end

  # a desk's name, as the workplace apps show it
  def self.name_of(asset : ::PlaceOS::Model::Asset) : String
    asset.identifier.presence || asset.name.presence || asset.id.to_s
  end

  # a desk's element id on the level map: desks imported from desk metadata keep it in
  # other_data, and the apps fall back to the asset id
  def self.map_id_of(asset : ::PlaceOS::Model::Asset) : String
    asset.map_id.presence || asset.other_data.try(&.as_h?).try(&.["map_id"]?).try(&.as_s?).presence || asset.id.to_s
  end

  ###############################################################################################

  @[AC::Route::Filter(:before_action)]
  private def block_guests
    raise Error::Forbidden.new("guests can't browse desks") if user_token.guest_scope?
  end

  # SQL limiting assets to the caller's authority, see `Assets#confirm_authority`
  AUTHORITY_SCOPE = "EXISTS (SELECT 1 FROM asset_type at JOIN asset_category ac ON ac.id = at.category_id WHERE at.id = asset.asset_type_id AND (ac.authority_id IS NULL OR ac.authority_id = ?))"

  private def authority_id : String
    current_authority.as(::PlaceOS::Model::Authority).id.as(String)
  end

  # the authority's desk asset type, the oldest `_DESKS_` type in the oldest `_DESKS_` category
  getter desk_type_id : String do
    category = ::PlaceOS::Model::AssetCategory
      .where(name: DESK_TYPE_NAME)
      .where("authority_id = ? OR authority_id IS NULL", authority_id)
      .order(:created_at).limit(1).to_a.first?
    type = category.try { |found| ::PlaceOS::Model::AssetType.where(name: DESK_TYPE_NAME, category_id: found.id).order(:created_at).limit(1).to_a.first? }
    raise Error::NotFound.new("desks haven't been set up, there's no #{DESK_TYPE_NAME} asset type") unless type
    type.id.as(String)
  end

  private def find_desk(id : String) : ::PlaceOS::Model::Asset
    found = ::PlaceOS::Model::Asset.where(id: id).where(AUTHORITY_SCOPE, authority_id).to_a.first?
    raise Error::NotFound.new("desk #{id} not found") unless found
    found
  end

  private def find_level(id : String) : ::PlaceOS::Model::Zone
    level = ::PlaceOS::Model::Zone.find?(id)
    raise Error::NotFound.new("level #{id} not found") unless level
    level
  end

  # the level's timezone, or its building's
  private def timezone_of(level : ::PlaceOS::Model::Zone) : Time::Location
    level.timezone || level.parent_id.try { |parent| ::PlaceOS::Model::Zone.find?(parent).try(&.timezone) } || DEFAULT_TIME_ZONE
  end

  # now, rounded up to the next 10 minutes so bookings don't start in the past
  private def bookable_now : Int64
    (Time.utc.to_unix / 600.0).ceil.to_i64 * 600
  end

  # the bookable desks on a level that the caller's groups can use, optionally matching a search
  private def level_desks(level_id : String, tsquery : String? = nil) : Array(::PlaceOS::Model::Asset)
    groups = user_token.user.roles
    group_clause = groups.empty? ? "" : " OR place_groups && #{sql_array(groups)}"
    args = [level_id, desk_type_id] of ::PgORM::Value
    args.concat groups
    query = ::PlaceOS::Model::Asset
      .where(AUTHORITY_SCOPE, authority_id)
      .where("zone_id = ? AND asset_type_id = ? AND bookable = TRUE AND (place_groups = '{}'#{group_clause})", args)
    query = query.where("search_vector @@ to_tsquery('simple', ?)", tsquery) if tsquery
    query.to_a
  end

  # the unique features of the bookable desks, in a zone when provided (a level or building)
  private def desk_features(zone_id : String? = nil) : Array(String)
    args = [desk_type_id] of ::PgORM::Value
    zone_clause = ""
    if zone_id
      zone_clause = " AND (zone_id = ? OR zones @> ARRAY[?]::text[])"
      args << zone_id << zone_id
    end
    index = 0
    sql = "SELECT DISTINCT unnest(features) AS feature FROM asset WHERE asset_type_id = ? AND bookable = TRUE#{zone_clause}".gsub("?") { "$#{index += 1}" }
    PgORM::Database.connection(&.query_all(sql, args: args, as: String)).sort!
  end

  # a page of the results, setting the same pagination headers as `paginate_sql`
  private def paginate(items : Array(T), type : String) : Array(T) forall T
    offset = search_offset
    limit = search_limit
    page = items[offset, limit]? || [] of T
    range_end = offset + page.size
    response.headers["X-Total-Count"] = items.size.to_s
    response.headers["Content-Range"] = "#{type} #{offset}-#{range_end}/#{items.size}"
    if range_end < items.size
      query_params["offset"] = range_end.to_s
      query_params["limit"] = limit.to_s
      response.headers["Link"] = %(<#{base_route}?#{query_params}>; rel="next")
    end
    page
  end

  # removes the desks booked in the period
  private def free!(desks : Array(::PlaceOS::Model::Asset), starting : Int64, ending : Int64) : Array(::PlaceOS::Model::Asset)
    return desks if desks.empty?
    probe = Booking.new(
      booking_type: "desk",
      booking_start: starting,
      booking_end: ending,
      asset_ids: desks.map(&.id.to_s),
      tenant_id: tenant.id,
    )
    booked = probe.clashing_bookings.flat_map(&.asset_ids).to_set
    desks.reject! { |asset| booked.includes?(asset.id.to_s) }
  end

  # a person's desk bookings that overlap the period
  private def desk_bookings(user_id : String?, email : String, starting : Int64, ending : Int64, limit : Int32) : Array(Booking)
    Booking.by_tenant(tenant.id)
      .by_user_or_email(user_id, email, false)
      .where(
        "booking_type = 'desk' AND booking_start < ? AND booking_end > ? AND rejected <> TRUE AND deleted <> TRUE AND checked_out_at IS NULL",
        ending, starting
      )
      .order(:booking_start)
      .limit(limit).to_a
  end

  ###############################################################################################

  # List the free desks on a level for a period, with your own desk bookings in that period.
  @[AC::MCP(root: true)]
  @[AC::Route::GET("/", converters: {features: ConvertStringArray})]
  def index(
    @[AC::Param::Info(description: "the level zone id", example: "zone-level")]
    zone_id : String,
    @[AC::Param::Info(description: "comma separated features, desks must have every feature", example: "standing,dual-monitor")]
    features : Array(String)? = nil,
    @[AC::Param::Info(description: "period start as a unix epoch in seconds, defaults to now", example: "1661725146")]
    period_start : Int64? = nil,
    @[AC::Param::Info(description: "period end as a unix epoch in seconds, defaults to the end of the period start's day", example: "1661743123")]
    period_end : Int64? = nil,
  ) : FreeDesks
    level = find_level(zone_id)
    location = timezone_of(level)
    period_start ||= bookable_now
    period_end ||= Time.unix(period_start).in(location).at_end_of_day.to_unix
    raise Error::BadRequest.new("period_end must be after period_start") unless period_end > period_start

    desks = free!(level_desks(zone_id, search_tsquery), period_start, period_end)
    available_features = desks.flat_map(&.features).uniq!.sort!
    if features && !features.empty?
      wanted = features.map(&.downcase)
      desks.select! { |asset| (wanted - asset.features.map(&.downcase)).empty? }
    end
    desks.sort_by! { |asset| Desks.name_of(asset) }

    mine = desk_bookings(user_token.id, user.email, period_start, period_end, 10).map { |booking| YourBooking.new(booking) }
    page = paginate(desks, ::PlaceOS::Model::Asset.table_name).map { |asset| Desk.new(asset) }
    FreeDesks.new(Level.new(level), location.name, period_start, period_end, available_features, desks.size, page, mine)
  end

  # List the features of the bookable desks, i.e. standing or dual-monitor.
  @[AC::Route::GET("/features")]
  def features(
    @[AC::Param::Info(description: "only desks in this zone, a building or level", example: "zone-building")]
    zone_id : String? = nil,
  ) : Array(String)
    desk_features(zone_id)
  end

  # List the free desks nearest to a desk, or to the desk a colleague has booked.
  @[AC::MCP(root: true)]
  @[AC::Route::GET("/nearby")]
  def nearby(
    @[AC::Param::Info(description: "the desk (asset id) to search near, required unless email is provided", example: "asset-1234")]
    asset_id : String? = nil,
    @[AC::Param::Info(description: "a colleague's email, searches near the desk they've booked", example: "colleague@org.com")]
    email : String? = nil,
    @[AC::Param::Info(description: "period start as a unix epoch in seconds, defaults to now, or to the start of the colleague's desk booking", example: "1661725146")]
    period_start : Int64? = nil,
    @[AC::Param::Info(description: "period end as a unix epoch in seconds, defaults to the end of the day, or of the colleague's desk booking", example: "1661743123")]
    period_end : Int64? = nil,
    @[AC::Param::Info(description: "the maximum number of desks to return, up to 100", example: "10")]
    limit : Int32 = 10,
  ) : NearbyDesks
    now = bookable_now
    seated = nil
    if email = email.presence.try(&.strip.downcase)
      # the colleague's next desk booking, within a day unless a period is provided
      starting = period_start || Time.utc.to_unix
      booking = desk_bookings(nil, email, starting, period_end || starting + 1.day.to_i, 1).first?
      raise Error::NotFound.new("#{email} hasn't booked a desk in this period") unless booking
      origin = find_desk(booking.asset_ids.first? || booking.asset_id)
      seated = email
      period_start ||= Math.max(booking.booking_start, now)
      period_end ||= booking.booking_end
    elsif id = asset_id.presence
      origin = find_desk(id)
    else
      raise Error::BadRequest.new("an asset_id or email is required")
    end

    level_id = origin.zone_id.as(String)
    level = find_level(level_id)
    location = timezone_of(level)
    period_start ||= now
    period_end ||= Time.unix(period_start).in(location).at_end_of_day.to_unix
    raise Error::BadRequest.new("period_end must be after period_start") unless period_end > period_start

    map_url = level.map_id.presence
    raise Error::NotFound.new("level #{level_id} doesn't have a map") unless map_url
    map = level_map(map_url)
    origin_map_id = Desks.map_id_of(origin)
    raise Error::NotFound.new("desk #{origin.id} (#{origin_map_id}) isn't drawn on the level map") unless map.centers.has_key?(origin_map_id)

    candidates = level_desks(level_id)
      .reject!(&.id.==(origin.id))
      .select! { |asset| map.centers.has_key?(Desks.map_id_of(asset)) }

    desks = free!(candidates, period_start, period_end)
      .map { |asset| Desk.new(asset, map.distance(origin_map_id, Desks.map_id_of(asset))) }
      .sort_by! { |desk| {desk.distance || Float64::MAX, desk.id} }
      .first(limit.clamp(1, MAX_RESULTS))

    NearbyDesks.new(Desk.new(origin), seated, Level.new(level), location.name, period_start, period_end, desks)
  end

  # Rank the free desks near where your colleagues are sitting, by level, defaulting to your contacts.
  @[AC::MCP(root: true)]
  @[AC::Route::GET("/near_colleagues", converters: {emails: ConvertStringArray})]
  def near_colleagues(
    @[AC::Param::Info(description: "comma separated colleague emails, defaults to your saved contacts", example: "jane@org.com,sam@org.com")]
    emails : Array(String)? = nil,
    @[AC::Param::Info(description: "period start as a unix epoch in seconds, defaults to now", example: "1661725146")]
    period_start : Int64? = nil,
    @[AC::Param::Info(description: "period end as a unix epoch in seconds, defaults to the end of the period start's day", example: "1661743123")]
    period_end : Int64? = nil,
    @[AC::Param::Info(description: "the maximum number of desks to return per level, up to 100", example: "10")]
    limit : Int32 = 10,
  ) : NearColleagues
    names = {} of String => String
    if emails.nil? || emails.empty?
      contacts = ::PlaceOS::Model::Metadata.where(parent_id: user_token.id, name: "contacts").to_a.first?
      contacts.try(&.details.as_a?).try &.each do |contact|
        next unless email = contact["email"]?.try(&.as_s?).try(&.strip.downcase).presence
        names[email] = contact["name"]?.try(&.as_s?) || email
      end
      emails = names.keys
    else
      emails = emails.map(&.strip.downcase).uniq!
    end
    raise Error::BadRequest.new("no colleagues: provide their emails or save them as contacts") if emails.empty?
    emails = emails.first(MAX_RESULTS)

    location = org_timezone
    period_start ||= bookable_now
    period_end ||= Time.unix(period_start).in(location).at_end_of_day.to_unix
    raise Error::BadRequest.new("period_end must be after period_start") unless period_end > period_start

    # each colleague's earliest desk booking in the period
    digests = emails.map { |email| ::PlaceOS::Model::Email.new(email).digest }
    args = digests.map(&.as(::PgORM::Value))
    args << period_end << period_start
    seated = {} of String => Booking
    Booking.by_tenant(tenant.id)
      .where(
        "booking_type = 'desk' AND email_digest = ANY(#{sql_array(digests)}) AND booking_start < ? AND booking_end > ? AND rejected <> TRUE AND deleted <> TRUE AND checked_out_at IS NULL",
        args
      )
      .order(:booking_start).to_a
      .each { |booking| seated[booking.user_email.to_s.downcase] ||= booking }

    desk_ids = seated.values.map { |booking| booking.asset_ids.first? || booking.asset_id }.uniq!
    desk_args = desk_ids.map(&.as(::PgORM::Value))
    desk_args << authority_id
    assets = desk_ids.empty? ? {} of String => ::PlaceOS::Model::Asset : ::PlaceOS::Model::Asset
      .where("id = ANY(#{sql_array(desk_ids)}) AND #{AUTHORITY_SCOPE}", desk_args)
      .to_a.index_by(&.id.to_s)

    unranked = [] of String
    by_level = Hash(String, Array(Colleague)).new { |hash, key| hash[key] = [] of Colleague }
    seated.each do |email, booking|
      asset = assets[booking.asset_ids.first? || booking.asset_id]?
      unless asset && (level_id = asset.zone_id)
        unranked << email
        next
      end
      by_level[level_id] << Colleague.new(email, names[email]? || booking.user_name.presence, Desk.new(asset), booking)
    end

    levels = by_level.compact_map do |level_id, colleagues|
      ranked = rank_near(level_id, colleagues, period_start, period_end, limit.clamp(1, MAX_RESULTS))
      unless ranked
        unranked.concat colleagues.map(&.email)
        next
      end
      ranked
    end
    levels.sort_by! { |level| -level.colleagues.size }

    NearColleagues.new(period_start, period_end, levels, emails - seated.keys, unranked)
  end

  # Borda count: every colleague ranks the free desks by distance and awards points in that
  # order, so a desk a fair walk from several colleagues beats one next to a single colleague.
  # nil when the level can't be ranked, i.e. it has no map
  private def rank_near(level_id : String, colleagues : Array(Colleague), starting : Int64, ending : Int64, limit : Int32) : ColleagueLevel?
    level = ::PlaceOS::Model::Zone.find?(level_id)
    return nil unless level && (url = level.map_id.presence)
    map = begin
      level_map(url)
    rescue error : Error::BadUpstreamResponse
      Log.warn(exception: error) { "unable to rank desks on level #{level_id}" }
      return nil
    end

    origins = colleagues.compact_map { |colleague| colleague.desk.map_id if map.centers.has_key?(colleague.desk.map_id) }
    return nil if origins.empty?

    candidates = free!(level_desks(level_id).select! { |asset| map.centers.has_key?(Desks.map_id_of(asset)) }, starting, ending)
    scores = Hash(String, Int32).new(0)
    distances = Hash(String, Float64).new(0.0)
    origins.each do |origin|
      ranked = candidates.map { |asset| {asset, map.distance(origin, Desks.map_id_of(asset)) || Float64::MAX} }.sort_by!(&.[1])
      ranked.each_with_index do |(asset, distance), index|
        scores[asset.id.to_s] += ranked.size - index
        distances[asset.id.to_s] += distance / origins.size
      end
    end

    desks = candidates
      .sort_by { |asset| {-scores[asset.id.to_s], Desks.name_of(asset)} }
      .first(limit)
      .map { |asset| Desk.new(asset, distances[asset.id.to_s]) }
    ColleagueLevel.new(Level.new(level), timezone_of(level).name, colleagues, desks)
  end

  # the organisation zone's timezone
  private def org_timezone : Time::Location
    org_zone = current_authority.try(&.config["org_zone"]?.try(&.as_s?))
    org_zone.try { |zone_id| ::PlaceOS::Model::Zone.find?(zone_id).try(&.timezone) } || DEFAULT_TIME_ZONE
  end

  # Book a desk: find a free desk on the right level, or near a colleague, and book it.
  @[AC::MCP(prompt: true, root: true, title: "Book a desk")]
  def book(
    @[AC::Param::Info(description: "when, i.e. tomorrow, next Monday or 2026-10-14", example: "tomorrow")]
    date : String? = nil,
    @[AC::Param::Info(description: "a colleague to sit near, by name or email", example: "Jane Smith")]
    near : String? = nil,
    @[AC::Param::Info(description: "desk features wanted, i.e. standing or dual monitors", example: "standing")]
    features : String? = nil,
  ) : String
    ask = String.build do |str|
      str << "Book me a desk"
      str << " for " << date if date.presence
      str << " near " << near if near.presence
      str << " with " << features if features.presence
      str << '.'
    end

    # the features to match a request against, the prompt still works without desks set up
    known = desk_features rescue [] of String
    unless known.empty?
      ask += " Desk features in use: #{known.first(50).join(", ")} (desks_features, in the desks toolbox, lists them for a building or level)."
    end

    <<-PROMPT
      #{ask}

      How to book a desk:
      1. Call users_current to see who I am. Work out dates and times in my building's
         timezone, as unix epochs in seconds.
      2. Find the building and level with the spaces toolbox's spaces_zones (tags building,
         then level with the building as parent_id). If there are several buildings and I
         haven't said which, ask me, don't guess. Match levels loosely: "first floor" is "level 1".
         Unless I name a level, sit me as close as possible to where I'll be that day: check my
         meetings with events_index (events toolbox, an event's system is its room and the
         room's zones its level) and prefer the level with the most of them, otherwise the
         nearest level to it in the same building.
      3. To sit near a colleague, find their email with the staff toolbox if you only have a
         name, then desks_nearby with their email gives the free desks closest to theirs,
         on their level and for their booking's times. To sit near several colleagues or my
         team, desks_near_colleagues ranks the free desks on each level by how close they are
         to all of them (it defaults to my saved contacts).
      4. Otherwise desks_index with the level's zone id and the period lists the free desks
         and their features. Prefer desks with the features I asked for.
      5. I can only hold one desk booking a day. desks_index lists mine as your_bookings: if I
         already have one that day, tell me and offer to cancel it with bookings_destroy
         before booking another.
      6. Book with bookings_book (booking_type desk, the desk's id as asset_id). Without
         times it books from now, or for a future day pass that day's start, until the end
         of the day. For several days, book each day separately.
      7. Once you have enough information, book it without asking me to confirm, its card shows
         me the booking and the desk on the map. Cancel anything booked on the wrong day.
      PROMPT
  end
end
