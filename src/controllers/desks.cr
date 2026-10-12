# Desks, the bookable desk assets on each level, ranked by how close they are to a desk or a colleague
class Desks < Application
  include Utils::SearchPagination

  base "/api/staff/v1/desks"

  # the most desks returned
  MAX_RESULTS = 50

  # a desk asset
  struct Desk
    include JSON::Serializable

    # the asset id, book it with this as the asset_id
    getter id : String
    getter name : String?
    getter map_id : String?
    # the level the desk is on
    getter zone_id : String?
    getter zones : Array(String)
    getter features : Array(String)
    getter? accessible : Bool
    # straight line distance from the origin desk, in level map units
    getter distance : Float64?

    def initialize(asset : ::PlaceOS::Model::Asset, @distance = nil)
      @id = asset.id.to_s
      @name = asset.name.presence
      @map_id = asset.map_id.presence
      @zone_id = asset.zone_id
      @zones = asset.zones
      @features = asset.features
      @accessible = asset.accessible
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

  # the available desks closest to the origin desk
  struct NearbyDesks
    include JSON::Serializable

    getter origin : Desk
    # who the origin desk is booked by, when searching near a colleague
    getter seated : String?
    getter level : Level
    getter timezone : String
    getter period_start : Int64
    getter period_end : Int64
    # available desks, nearest first
    getter desks : Array(Desk)

    def initialize(@origin, @seated, @level, @timezone, @period_start, @period_end, @desks)
    end
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

  private def find_desk(id : String) : ::PlaceOS::Model::Asset
    found = ::PlaceOS::Model::Asset.where(id: id).where(AUTHORITY_SCOPE, authority_id).to_a.first?
    raise Error::NotFound.new("desk #{id} not found") unless found
    found
  end

  # the colleague's earliest desk booking in the period
  private def seated_booking(email : String, starting : Int64, ending : Int64) : Booking
    booking = Booking.by_tenant(tenant.id)
      .by_user_or_email(nil, email, false)
      .where(
        "booking_type = 'desk' AND booking_start < ? AND booking_end > ? AND rejected <> TRUE AND deleted <> TRUE AND checked_out_at IS NULL",
        ending, starting
      )
      .order(:booking_start)
      .limit(1).to_a.first?
    raise Error::NotFound.new("#{email} hasn't booked a desk in this period") unless booking
    booking
  end

  ###############################################################################################

  # List the available desks nearest to a desk, or to the desk a colleague has booked.
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
    @[AC::Param::Info(description: "the maximum number of desks to return, up to 50", example: "10")]
    limit : Int32 = 10,
  ) : NearbyDesks
    now = Time.utc.to_unix
    seated = nil
    if email = email.presence.try(&.strip.downcase)
      # the colleague's next desk booking, within a day unless a period is provided
      booking = seated_booking(email, period_start || now, period_end || (period_start || now) + 1.day.to_i)
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
    level = ::PlaceOS::Model::Zone.find!(level_id)
    location = level.timezone || level.parent_id.try { |parent| ::PlaceOS::Model::Zone.find?(parent).try(&.timezone) } || DEFAULT_TIME_ZONE
    period_start ||= now
    period_end ||= Time.unix(period_start).in(location).at_end_of_day.to_unix
    raise Error::BadRequest.new("period_end must be after period_start") unless period_end > period_start

    origin_map_id = origin.map_id.presence
    raise Error::NotFound.new("desk #{origin.id} isn't on a level map") unless origin_map_id
    map_url = level.map_id.presence
    raise Error::NotFound.new("level #{level_id} doesn't have a map") unless map_url
    map = level_map(map_url)
    raise Error::NotFound.new("desk #{origin.id} (#{origin_map_id}) isn't drawn on the level map") unless map.centers.has_key?(origin_map_id)

    # bookable desks of the same kind (asset category) on the level, that the caller's groups can use
    groups = user_token.user.roles
    group_clause = groups.empty? ? "" : " OR place_groups && #{sql_array(groups)}"
    args = [level_id, origin.id, origin.asset_type_id] of ::PgORM::Value
    args.concat groups
    candidates = ::PlaceOS::Model::Asset
      .where(AUTHORITY_SCOPE, authority_id)
      .where(
        "zone_id = ? AND bookable = TRUE AND id <> ? AND asset_type_id IN (SELECT id FROM asset_type WHERE category_id = (SELECT category_id FROM asset_type WHERE id = ?)) AND (place_groups = '{}'#{group_clause})",
        args
      ).to_a
      .select! { |asset| asset.map_id.presence.try { |map_id| map.centers.has_key?(map_id) } }

    # remove the desks that are booked in the period
    unless candidates.empty?
      probe = Booking.new(
        booking_type: "desk",
        booking_start: period_start,
        booking_end: period_end,
        asset_ids: candidates.map(&.id.to_s),
        tenant_id: tenant.id,
      )
      booked = probe.clashing_bookings.flat_map(&.asset_ids).to_set
      candidates.reject! { |asset| booked.includes?(asset.id.to_s) }
    end

    desks = candidates
      .map { |asset| Desk.new(asset, map.distance(origin_map_id, asset.map_id.as(String))) }
      .sort_by! { |desk| {desk.distance || Float64::MAX, desk.id} }
      .first(limit.clamp(1, MAX_RESULTS))

    NearbyDesks.new(Desk.new(origin), seated, Level.new(level), location.name, period_start, period_end, desks)
  end
end
