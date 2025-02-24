require "placeos"
require "promise"

# Helper to interact with PlaceOS API
module Utils::PlaceOSHelpers
  # Base URL of the PlaceOS instance we are interacting with
  PLACE_URI = App::PLACE_URI

  @placeos_client : PlaceOS::Client? = nil

  def get_placeos_client : PlaceOS::Client
    @placeos_client ||= if App.running_in_production?
                          if key = request.headers["X-API-Key"]?
                            PlaceOS::Client.new(
                              PLACE_URI,
                              host_header: request.headers["Host"]?,
                              insecure: ::App::SSL_VERIFY_NONE,
                              x_api_key: key
                            )
                          else
                            PlaceOS::Client.new(
                              PLACE_URI,
                              token: OAuth2::AccessToken::Bearer.new(acquire_token.not_nil!, nil),
                              host_header: request.headers["Host"]?,
                              insecure: ::App::SSL_VERIFY_NONE
                            )
                          end
                        else
                          PlaceOS::Client.from_environment_user
                        end
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
  )
    calendars = Set.new((calendars || "").split(',').compact_map(&.strip.downcase.presence))

    # Create a map of calendar ids to systems
    # only obtain events for calendars the user has access to
    system_calendars = if calendars.size > 0
                         if tenant.using_service_account? || tenant.delegated
                           calendars.each_with_object({} of String => PlaceOS::Client::API::Models::System?) { |calendar, obj| obj[calendar] = nil }
                         else
                           user_calendars = Set.new(client.list_calendars(user.email).compact_map(&.id.try &.downcase.presence))
                           (calendars & user_calendars).each_with_object({} of String => PlaceOS::Client::API::Models::System?) { |calendar, obj| obj[calendar] = nil }
                         end
                       else
                         {} of String => PlaceOS::Client::API::Models::System?
                       end

    # Check if we want to grab systems from zones
    zones = (zone_ids || "").split(',').compact_map(&.strip.presence).uniq!
    if zones.size > 0
      systems = get_placeos_client.systems

      # perform requests in parallel (map-reduce)
      Promise.all(zones.map { |zone_id|
        Promise.defer {
          systems.search(
            zone_id: zone_id,
            features: features,
            capacity: capacity,
            bookable: bookable
          )
        }
      }).get.each do |results|
        results.each do |system|
          calendar = system.email.presence
          next unless calendar
          system_calendars[calendar.downcase] = system
        end
      end
    end

    # Check if we want to grab individual systems
    system_ids = (system_ids || "").split(',').compact_map(&.strip.presence).uniq!
    if system_ids.size > 0
      systems = get_placeos_client.systems

      # perform requests in parallel (map-reduce)
      Promise.all(system_ids.map { |system_id|
        Promise.defer { systems.fetch(system_id) }
      }).get.each do |system|
        calendar = system.email.presence
        next unless calendar
        system_calendars[calendar.downcase] = system
      end
    end

    # default to the current user if no params were passed
    system_calendars[user.email.downcase] = nil if allow_default && system_calendars.empty? && calendars.empty? && zones.empty? && system_ids.empty?

    system_calendars
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
