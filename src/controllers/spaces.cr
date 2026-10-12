# Spaces, the bookable rooms in the organisation's buildings, with the zones and room features to filter them by
class Spaces < Application
  include Utils::SearchPagination

  base "/api/staff/v1/spaces"

  # a bookable room, a PlaceOS system with a resource calendar
  struct Space
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?
    getter description : String?
    getter email : String?
    getter capacity : Int32
    getter features : Array(String)
    getter images : Array(String)
    getter map_id : String?
    getter zones : Array(String)
    getter timezone : String?
    # bookings need to be approved
    getter? approval : Bool

    def initialize(system : ::PlaceOS::Model::ControlSystem)
      @id = system.id.as(String)
      @name = system.name
      @display_name = system.display_name.presence
      @description = system.description.presence
      @email = system.email.try(&.to_s).presence
      @capacity = system.capacity
      @features = system.features.to_a.sort!
      @images = system.images
      @map_id = system.map_id.presence
      @zones = system.zones
      @timezone = system.timezone.try(&.name)
      @approval = system.approval
    end
  end

  # a campus, building, level or area
  struct SpaceZone
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?
    getter tags : Array(String)
    getter parent_id : String?
    getter location : String?
    getter timezone : String?

    def initialize(zone : ::PlaceOS::Model::Zone)
      @id = zone.id.as(String)
      @name = zone.name
      @display_name = zone.display_name.presence
      @tags = zone.tags.to_a.sort!
      @parent_id = zone.parent_id.presence
      @location = zone.location.presence
      @timezone = zone.timezone.try(&.name)
    end
  end

  # the rooms free for a meeting, in a building or level
  struct FreeSpaces
    include JSON::Serializable

    # the buildings to choose from
    getter buildings : Array(SpaceZone)
    # where the rooms were looked for, null until a building is picked
    @[JSON::Field(emit_null: true)]
    getter zone_id : String?
    # smallest first
    getter spaces : Array(Space)

    def initialize(@buildings, @zone_id, @spaces)
    end
  end

  # a meeting in the space's calendar
  struct SpaceEvent
    include JSON::Serializable

    getter id : String?
    # hidden for other people's private meetings
    getter title : String?
    getter host : String?
    getter event_start : Int64
    getter event_end : Int64?
    getter? all_day : Bool
    getter? private : Bool

    def initialize(event : PlaceCalendar::Event, viewer : String)
      @id = event.id
      @private = event.private?
      @title = @private && event.host.try(&.downcase) != viewer ? nil : event.title
      @host = event.host
      @event_start = event.event_start.to_unix
      @event_end = event.event_end.try(&.to_unix)
      @all_day = event.all_day?
    end
  end

  # a space with its meetings over a period
  struct SpaceSchedule
    include JSON::Serializable

    getter space : Space
    # the space's zones, i.e. its building and level
    getter zones : Array(SpaceZone)
    getter timezone : String
    getter period_start : Int64
    getter period_end : Int64
    # nil when the calendar couldn't be read, see `events_error`
    getter events : Array(SpaceEvent)?
    getter events_error : String?

    def initialize(@space, @zones, @timezone, @period_start, @period_end, @events, @events_error)
    end
  end

  ###############################################################################################

  @[AC::Route::Filter(:before_action)]
  private def block_guests
    raise Error::Forbidden.new("guests can't browse spaces") if user_token.guest_scope?
  end

  @[AC::Route::Filter(:before_action, only: [:show, :image, :map])]
  private def find_space(id : String)
    Log.context.set(system_id: id)
    clause, args = space_scope
    found = ::PlaceOS::Model::ControlSystem.where(id: id).where(clause, args).to_a.first?
    raise Error::NotFound.new("space #{id} not found") unless found
    @current_space = found
  end

  getter! current_space : ::PlaceOS::Model::ControlSystem

  # the authority's organisation zone, spaces and zones are limited to it when configured
  private def org_zone_id : String?
    current_authority.try(&.config["org_zone"]?.try(&.as_s?))
  end

  # the zones in the organisation's tree, every zone when there's no org zone
  private def org_zones
    zones = ::PlaceOS::Model::Zone.all
    if org = org_zone_id
      zones = zones.where(<<-SQL, org)
        id IN (
          WITH RECURSIVE tree(id) AS (
            SELECT ?::text
            UNION
            SELECT z.id FROM "zone" z INNER JOIN tree t ON z.parent_id = t.id
          )
          SELECT id FROM tree
        )
        SQL
    end
    zones
  end

  # SQL limiting systems to bookable ones in every zone listed and the org zone
  private def space_scope(zone_ids : Array(String)? = nil) : Tuple(String, Array(::PgORM::Value))
    clauses = ["bookable = true"]
    args = [] of ::PgORM::Value
    zones = zone_ids.try(&.dup) || [] of String
    org_zone_id.try { |org| zones << org }
    zones.uniq!
    unless zones.empty?
      clauses << "zones @> #{sql_array(zones)}"
      args.concat zones
    end
    {clauses.join(" AND "), args}
  end

  ###############################################################################################

  # List the bookable spaces (rooms), filtered by zones, features and capacity.
  @[AC::Route::GET("/", converters: {zone_ids: ConvertStringArray, features: ConvertStringArray})]
  def index(
    @[AC::Param::Info(description: "comma separated zone ids, spaces must be in every zone, i.e. a building and a level", example: "zone-building,zone-level")]
    zone_ids : Array(String)? = nil,
    @[AC::Param::Info(description: "comma separated features, spaces must have every feature", example: "whiteboard,vidconf")]
    features : Array(String)? = nil,
    @[AC::Param::Info(description: "minimum number of people the space seats", example: "6")]
    capacity : Int32? = nil,
  ) : Array(Space)
    clause, args = space_scope(zone_ids)
    query = ::PlaceOS::Model::ControlSystem.where(clause, args)

    if features && !features.empty?
      query = query.where("features @> #{sql_array(features)}", features)
    end
    query = query.where("capacity >= ?", capacity) if capacity

    paginate_search(query, ::PlaceOS::Model::ControlSystem.table_name).map { |system| Space.new(system) }
  end

  # List the unique features of the bookable spaces, i.e. whiteboard or vidconf.
  @[AC::Route::GET("/features", converters: {zone_ids: ConvertStringArray})]
  def features(
    @[AC::Param::Info(description: "comma separated zone ids, only features of spaces in every zone", example: "zone-building,zone-level")]
    zone_ids : Array(String)? = nil,
  ) : Array(String)
    clause, args = space_scope(zone_ids)
    index = 0
    sql = "SELECT DISTINCT unnest(features) AS feature FROM sys WHERE #{clause} ORDER BY feature".gsub("?") { "$#{index += 1}" }
    PgORM::Database.connection(&.query_all(sql, args: args, as: String))
  end

  # List the zones (campuses, buildings, levels and areas) that spaces are in.
  @[AC::Route::GET("/zones", converters: {tags: ConvertStringArray})]
  def zones(
    @[AC::Param::Info(description: "comma separated tags, zones must have every tag, i.e. building or level", example: "building")]
    tags : Array(String)? = nil,
    @[AC::Param::Info(description: "only the child zones of this zone, i.e. the levels of a building", example: "zone-building")]
    parent_id : String? = nil,
    @[AC::Param::Info(name: "q", description: "filters zones by name, the last word matches as a prefix", example: "level")]
    query : String = "*",
    @[AC::Param::Info(description: "the maximum number of results to return", example: "100")]
    limit : UInt32 = 100_u32,
    @[AC::Param::Info(description: "the starting offset of the result set, used to implement pagination")]
    offset : UInt32 = 0_u32,
  ) : Array(SpaceZone)
    build_search_params(query, limit, offset)
    zones = org_zones
    zones = zones.where(parent_id: parent_id) if parent_id
    if tags && !tags.empty?
      zones = zones.where("tags @> #{sql_array(tags)}", tags)
    end

    paginate_search(zones, ::PlaceOS::Model::Zone.table_name).map { |zone| SpaceZone.new(zone) }
  end

  # Find the rooms in a building or level that are free for a whole meeting.
  @[AC::MCP(visibility: :card)]
  @[AC::Route::GET("/free")]
  def free(
    @[AC::Param::Info(description: "meeting start as a unix epoch in seconds", example: "1661725146")]
    period_start : Int64,
    @[AC::Param::Info(description: "meeting end as a unix epoch in seconds, at most a day after the start", example: "1661728746")]
    period_end : Int64,
    @[AC::Param::Info(description: "the building or level to look in, defaults to the only building", example: "zone-building")]
    zone_id : String? = nil,
    @[AC::Param::Info(description: "minimum number of people the room seats", example: "2")]
    capacity : Int32? = nil,
  ) : FreeSpaces
    starting = Time.unix(period_start)
    ending = Time.unix(period_end)
    unless starting < ending && ending - starting <= 1.day
      raise AC::Route::Param::ValueError.new("must be after period_start and at most a day after it", "period_end")
    end

    buildings = org_zones.where("tags @> #{sql_array(["building"])}", ["building"]).to_a
      .sort_by! { |zone| (zone.display_name.presence || zone.name).downcase }
      .map { |zone| SpaceZone.new(zone) }
    zone_id ||= buildings.first.id if buildings.size == 1
    return FreeSpaces.new(buildings, nil, [] of Space) unless zone_id

    clause, args = space_scope([zone_id])
    query = ::PlaceOS::Model::ControlSystem.where(clause, args).where("email IS NOT NULL AND email <> ?", "")
    query = query.where("capacity >= ?", capacity) if capacity
    systems = query.to_a
    free = free_calendars(systems.compact_map(&.email.try(&.to_s.presence)), starting, ending).to_set
    spaces = systems
      .select { |system| system.email.to_s.downcase.in?(free) }
      .sort_by! { |system| {system.capacity, system.name} }
      .map { |system| Space.new(system) }
    FreeSpaces.new(buildings, zone_id, spaces)
  end

  # Show a space and its meetings, defaulting to today, with a card for booking it.
  @[AC::MCP(ui: "spaces/card.html")]
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(description: "period start as a unix epoch in seconds, defaults to the start of today in the space's timezone", example: "1661725146")]
    period_start : Int64? = nil,
    @[AC::Param::Info(description: "period end as a unix epoch in seconds, defaults to the end of the period start's day", example: "1661743123")]
    period_end : Int64? = nil,
  ) : SpaceSchedule
    system = current_space
    zone_ids = system.zones
    zones = zone_ids.empty? ? [] of ::PlaceOS::Model::Zone : ::PlaceOS::Model::Zone.find_all(zone_ids).to_a
    # the most specific zone with a timezone, systems list their zones from org down to level
    location = system.timezone ||
               zone_ids.reverse.compact_map { |zone_id| zones.find(&.id.==(zone_id)).try(&.timezone) }.first? ||
               DEFAULT_TIME_ZONE

    starting = period_start ? Time.unix(period_start).in(location) : Time.local(location).at_beginning_of_day
    ending = period_end ? Time.unix(period_end) : starting.at_end_of_day

    events = nil
    events_error = nil
    if calendar = system.email.try(&.to_s).presence
      begin
        events = client.list_events(user.email, calendar, period_start: starting, period_end: ending)
          .reject { |event| event.status == "cancelled" }
          .sort_by!(&.event_start)
          .map { |event| SpaceEvent.new(event, user.email.downcase) }
      rescue error
        Log.warn(exception: error) { "unable to list events for space #{system.id}" }
        events_error = "unable to read the space's calendar: #{error.message}"
      end
    else
      events_error = "the space has no calendar"
    end

    space_zones = zone_ids.compact_map { |zone_id| zones.find(&.id.==(zone_id)) }.map { |zone| SpaceZone.new(zone) }
    SpaceSchedule.new(Space.new(system), space_zones, location.name, starting.to_unix, ending.to_unix, events, events_error)
  end

  # Get one of the space's images.
  @[AC::MCP(visibility: :card)]
  @[AC::Route::GET("/:id/images/:index")]
  def image(
    @[AC::Param::Info(description: "the image's position in the space's images, from 0", example: "0")]
    index : Int32,
  ) : Nil
    url = current_space.images[index]? if index >= 0
    raise Error::NotFound.new("space #{current_space.id} has no image #{index}") unless url

    file = fetch_upload(url, "image/*", MAX_CARD_FILE_BYTES, "space image")
    media_type = StaffApi::Upload.image_type(file, url)
    raise Error::BadUpstreamResponse.new("the space image #{url} isn't an image (#{file.media_type})") unless media_type

    @__render_called__ = true
    if file.truncated
      response.status = :payload_too_large
      response.content_type = "text/plain"
      response.print "the image is too large to return"
    else
      response.content_type = media_type
      response.print file.body
    end
  end

  # Get the space's level map, an SVG, with the space's position in the X-Map-Pin header.
  @[AC::MCP(visibility: :card)]
  @[AC::Route::GET("/:id/map")]
  def map : Nil
    system = current_space
    zones = system.zones.empty? ? [] of ::PlaceOS::Model::Zone : ::PlaceOS::Model::Zone.find_all(system.zones).to_a.select!(&.map_id.presence)
    # the space's level, otherwise its most specific zone with a map (systems list zones from the org down)
    level = zones.find(&.tags.includes?("level")) ||
            system.zones.reverse.compact_map { |zone_id| zones.find(&.id.==(zone_id)) }.first?
    raise Error::NotFound.new("space #{system.id} isn't on a level with a map") unless level
    render_level_map(level, system.map_id.presence || system.id.as(String))
  end

  # Book a meeting room: find rooms that fit, check they and the people invited are free, and book it.
  @[AC::MCP(prompt: true, root: true, title: "Book a meeting room")]
  def book(
    @[AC::Param::Info(description: "when and for how long, i.e. tomorrow at 2pm for an hour", example: "tomorrow 2pm, 1 hour")]
    time : String? = nil,
    @[AC::Param::Info(description: "the people to invite, by name or email", example: "Jane Smith, bob@org.com")]
    attendees : String? = nil,
    @[AC::Param::Info(description: "how many people the room needs to seat", example: "6")]
    size : String? = nil,
    @[AC::Param::Info(description: "room features wanted, i.e. a whiteboard or video conferencing", example: "vidconf")]
    needs : String? = nil,
    @[AC::Param::Info(description: "the meeting title", example: "Project catch up")]
    title : String? = nil,
  ) : String
    ask = String.build do |str|
      str << "Book me a meeting room"
      str << " for " << time if time.presence
      str << " with " << attendees if attendees.presence
      str << " for " << size << " people" if size.presence
      str << " with " << needs if needs.presence
      str << ", titled \"" << title << '"' if title.presence
      str << '.'
    end
    room_features = self.features(nil).first(50)
    unless room_features.empty?
      ask += " Room features in use: #{room_features.join(", ")} (spaces_features lists them for a building or level)."
    end

    <<-PROMPT
      #{ask}

      How to book a meeting room:
      1. Call users_current to see who I am. Work out times in the building's timezone, as unix
         epochs in seconds. Ask me for anything missing (when, how long, the title) before booking.
      2. If you only have people's names, find their emails with the staff toolbox; confirm with
         me when several people match, don't guess. Check the people I work with are free with
         calendars_free_busy (calendars toolbox), passing their emails, and suggest other times
         if they're busy.
      3. Find the building and level with the spaces toolbox's spaces_zones. If there are several
         buildings and I haven't said which, ask me. Unless I name a level, book a room as close as
         possible to my desk that day: find my desk booking with bookings_index (bookings toolbox,
         type desk, its zones give the level) and prefer rooms on that level, then the nearest
         levels to it in the same building. Match levels loosely: "first floor" is "level 1".
      4. Find rooms that are free for the whole meeting with calendars_availability (calendars
         toolbox): the period, the level's zone id in zone_ids, capacity for everyone including me,
         the features I need and bookable true. Widen to the building when the level has none free.
      5. Pick the smallest room that fits and has the features, on the closest level. If none are
         free, offer the nearest free times (calendars_free_busy with the rooms' system_ids) or
         another level.
      6. Book with events_book: the title, event_start, event_end, the people's emails as
         attendees (I'm added as the host, the room comes from system_id) and the room's
         system_id. If the room needs approval, tell me the booking is pending approval.
      7. Once you have enough information, book it without asking me to confirm, then call
         events_show with the event's id to show me the meeting.
      PROMPT
  end
end
