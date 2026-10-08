require "redis-cluster"

# Helpers for interacting with PlaceOS resources
module Utils::PlaceOSHelpers
  # The authority (PlaceOS domain) this request is being made against
  getter current_authority : PlaceOS::Model::Authority? { PlaceOS::Model::Authority.find_by_domain(request.hostname.as(String)) }

  # Systems
  # =======

  # Guests can only access the systems they've been invited to.
  # Some routes allow unauthenticated requests (i.e. adding an attendee to a public event)
  def find_system!(id : String) : PlaceOS::Model::ControlSystem
    if auth_token_present? && user_token.guest_scope? && !user_token.user.roles.includes?(id)
      raise Error::Forbidden.new("guest #{user_token.id} cannot access system #{id}")
    end
    PlaceOS::Model::ControlSystem.find!(id)
  end

  def systems_with_emails(emails : Enumerable(String)) : Array(PlaceOS::Model::ControlSystem)
    emails = emails.map(&.strip.downcase).uniq!
    return [] of PlaceOS::Model::ControlSystem if emails.empty?
    PlaceOS::Model::ControlSystem.where(email: emails).to_a
  end

  # Signals
  # =======

  @@redis : Redis::Client? = nil
  @@redis_lock = Mutex.new

  protected def self.with_redis(&)
    @@redis_lock.synchronize do
      redis = @@redis ||= Redis::Client.boot(App::REDIS_URL)
      yield redis
    end
  end

  # Publishes JSON data to drivers and frontends listening on the channel,
  # both globally and scoped to this domain's authority.
  # A failed signal is logged and doesn't fail the request.
  def signal(channel : String, payload) : Nil
    data = payload.to_json
    paths = ["placeos/#{channel}"]
    if authority_id = current_authority.try(&.id)
      paths << "placeos/#{authority_id}/#{channel}"
    end

    Utils::PlaceOSHelpers.with_redis do |redis|
      paths.each { |path| redis.publish(path, data) }
    end
  rescue error
    ::App::Log.error(exception: error) { "failed to signal #{channel}" }
  end

  # Get the list of local calendars this user has access to
  def get_user_calendars
    client.list_calendars(user.email, only_writable: true)
  end

  def matching_calendar_ids(
    calendars : String? = nil,
    zone_ids : String? = nil,
    system_ids : String? = nil,
    features : String? = nil,
    capacity : Int32? = nil,
    bookable : Bool? = nil,
    allow_default = false,
  ) : Hash(String, PlaceOS::Model::ControlSystem?)
    calendars = Set.new(split_list(calendars).map(&.downcase))
    zones = split_list(zone_ids)
    system_ids = split_list(system_ids)

    # Create a map of calendar ids to systems
    # only obtain events for calendars the user has access to
    system_calendars = {} of String => PlaceOS::Model::ControlSystem?
    unless calendars.empty?
      unless tenant.using_service_account? || tenant.delegated
        calendars &= Set.new(client.list_calendars(user.email).compact_map(&.id.try &.downcase.presence))
      end
      calendars.each { |calendar| system_calendars[calendar] = nil }
    end

    # Grab systems from zones and individual systems
    systems = zones.empty? ? [] of PlaceOS::Model::ControlSystem : Utils::PlaceOSHelpers.systems_in_zones(zones, split_list(features), capacity, bookable)
    systems.concat system_ids.map { |system_id| find_system!(system_id) }
    systems.each do |system|
      calendar = system.email.to_s.downcase.presence
      system_calendars[calendar] = system if calendar
    end

    # default to the current user if no params were passed
    system_calendars[user.email.downcase] = nil if allow_default && system_calendars.empty? && calendars.empty? && zones.empty? && system_ids.empty?

    system_calendars
  end

  # Systems that are in any of the zones and match all of the filters
  def self.systems_in_zones(zones : Array(String), features : Array(String), capacity : Int32?, bookable : Bool?) : Array(PlaceOS::Model::ControlSystem)
    query = PlaceOS::Model::ControlSystem.where("zones && #{sql_array(zones)}", zones)
    query = query.where("features @> #{sql_array(features)}", features) unless features.empty?
    query = query.where("capacity >= ?", capacity) if capacity
    query = query.where(bookable: bookable) unless bookable.nil?
    query.to_a
  end

  # placeholders for binding an array of values: "ARRAY[?, ?, ...]::text[]"
  protected def self.sql_array(list : Array(String)) : String
    "ARRAY[#{list.join(", ") { "?" }}]::text[]"
  end

  private def split_list(list : String?) : Array(String)
    (list || "").split(',').compact_map(&.strip.presence).uniq!
  end

  enum Permission
    None
    Manage
    Admin
    Deny

    def can_manage?
      manage? || admin?
    end

    def forbidden?
      deny? || none?
    end
  end

  class PermissionsMeta
    include JSON::Serializable

    getter deny : Array(String)?
    getter manage : Array(String)?
    getter admin : Array(String)?

    # Returns {permission_found, access_level}
    def has_access?(groups : Array(String)) : Tuple(Bool, Permission)
      groups.map! &.downcase

      case
      when (is_deny = deny.try(&.map!(&.downcase))) && !(is_deny & groups).empty?
        {false, Permission::Deny}
      when (can_manage = manage.try(&.map!(&.downcase))) && !(can_manage & groups).empty?
        {true, Permission::Manage}
      when (can_admin = admin.try(&.map!(&.downcase))) && !(can_admin & groups).empty?
        {true, Permission::Admin}
      else
        {true, Permission::None}
      end
    end
  end

  # https://docs.google.com/document/d/1OaZljpjLVueFitmFWx8xy8BT8rA2lITyPsIvSYyNNW8/edit#
  # See the section on user-permissions
  def check_access(groups : Array(String), zones : Array(String))
    metadatas = PlaceOS::Model::Metadata.where(
      parent_id: zones,
      name: "permissions"
    ).to_a.to_h { |meta| {meta.parent_id, meta} }

    access = Permission::None
    zones.each do |zone_id|
      if metadata = metadatas[zone_id]?.try(&.details)
        continue, permission = PermissionsMeta.from_json(metadata.to_json).has_access?(groups)
        access = permission unless permission.none?
        break unless continue
      end
    end
    access
  end
end
