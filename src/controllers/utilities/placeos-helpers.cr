require "placeos"
require "promise"

# Helper to interact with PlaceOS API
module Utils::PlaceOSHelpers
  # Base URL of the PlaceOS instance we are interacting with
  PLACE_URI = App::PLACE_URI

  @placeos_client : PlaceOS::Client? = nil

  def get_placeos_client : PlaceOS::Client
    @placeos_client ||= if App.running_in_production?
                          PlaceOS::Client.new(
                            PLACE_URI,
                            token: OAuth2::AccessToken::Bearer.new(acquire_token.not_nil!, nil)
                          )
                        else
                          PlaceOS::Client.from_environment_user
                        end
  end

  # Get the list of local calendars this user has access to
  def get_user_calendars
    client.list_calendars(user.email, only_writable: true)
  end

  class CalendarSelection < Params
    attribute calendars : String?
    attribute zone_ids : String?
    attribute system_ids : String?
    attribute features : String?
    attribute capacity : Int32?
    attribute bookable : Bool?
  end

  def matching_calendar_ids
    args = CalendarSelection.new(params)
    # Create a map of calendar ids to systems
    system_calendars = {} of String => PlaceOS::Client::API::Models::System?

    # only obtain events for calendars the user has access to
    calendars = Set.new((args.calendars || "").split(',').map(&.strip.downcase).reject(&.empty?))
    user_calendars = Set.new(client.list_calendars(user.email).compact_map(&.id.try &.downcase))
    if calendars.size > 0
      (calendars & user_calendars).each do |calendar|
        system_calendars[calendar] = nil
      end
    end

    # Check if we want to grab systems from zones
    zones = (args.zone_ids || "").split(',').map(&.strip).reject(&.empty?).uniq
    if zones.size > 0
      systems = get_placeos_client.systems

      # perform requests in parallel (map-reduce)
      Promise.all(zones.map { |zone_id|
        Promise.defer {
          systems.search(
            zone_id: zone_id,
            features: args.features,
            capacity: args.capacity,
            bookable: args.bookable
          )
        }
      }).get.each do |results|
        results.each do |system|
          calendar = system.email
          next unless calendar
          next if calendar.empty?
          system_calendars[calendar] = system
        end
      end
    end

    # Check if we want to grab individual systems
    system_ids = (args.system_ids || "").split(',').map(&.strip).reject(&.empty?).uniq
    if system_ids.size > 0
      systems = get_placeos_client.systems

      # perform requests in parallel (map-reduce)
      Promise.all(system_ids.map { |system_id|
        Promise.defer { systems.fetch(system_id) }
      }).get.each do |system|
        calendar = system.email
        next unless calendar
        next if calendar.empty?
        system_calendars[calendar] = system
      end
    end

    system_calendars
  end

  enum Access
    None
    Manage
    Admin
  end

  class PermissionsMeta
    include JSON::Serializable

    getter deny : Array(String)?
    getter manage : Array(String)?
    getter admin : Array(String)?

    # Returns {permission_found, access_level}
    def has_access?(groups : Array(String)) : Tuple(Bool, Access)
      if none = deny
        return {true, Access::None} unless (none & groups).empty?
      end

      if can_manage = manage
        return {true, Access::Manage} unless (can_manage & groups).empty?
      end

      if can_admin = admin
        return {true, Access::Admin} unless (can_admin & groups).empty?
      end

      {false, Access::None}
    end
  end

  # https://docs.google.com/document/d/1OaZljpjLVueFitmFWx8xy8BT8rA2lITyPsIvSYyNNW8/edit#
  # See the section on user-permissions
  def check_access(groups : Array(String), system)
    client = get_placeos_client.metadata
    check = [system.id] + system.zones
    access = Access::None
    check.each do |area_id|
      if metadata = client.fetch(area_id, "permissions")["permissions"]?.try(&.details)
        continue, access = PermissionsMeta.from_json(metadata.to_json).has_access?(groups)
        break unless continue
      end
    end
    access
  end
end
