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

  @[AC::Route::Filter(:before_action, only: [:show])]
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
    zones = zones.where(parent_id: parent_id) if parent_id
    if tags && !tags.empty?
      zones = zones.where("tags @> #{sql_array(tags)}", tags)
    end

    paginate_search(zones, ::PlaceOS::Model::Zone.table_name).map { |zone| SpaceZone.new(zone) }
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
end
