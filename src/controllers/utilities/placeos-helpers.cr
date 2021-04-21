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

  # ameba:disable Metrics/CyclomaticComplexity
  def matching_calendar_ids(allow_default = false)
    args = CalendarSelection.new(params)

    calendars = Set.new((args.calendars || "").split(',').compact_map(&.strip.downcase.presence))
    user_calendars = Set.new(client.list_calendars(user.email).compact_map(&.id.try &.downcase.presence))

    # Create a map of calendar ids to systems
    # only obtain events for calendars the user has access to
    system_calendars = if calendars.size > 0
                         (calendars & user_calendars).each_with_object({} of String => PlaceOS::Client::API::Models::System?) { |calendar, obj| obj[calendar] = nil }
                       else
                         {} of String => PlaceOS::Client::API::Models::System?
                       end

    # Check if we want to grab systems from zones
    zones = (args.zone_ids || "").split(',').compact_map(&.strip.presence).uniq!
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
    system_ids = (args.system_ids || "").split(',').compact_map(&.strip.presence).uniq!
    if system_ids.size > 0
      systems = get_placeos_client.systems

      # perform requests in parallel (map-reduce)
      Promise.all(system_ids.map { |system_id|
        Promise.defer { systems.fetch(system_id) }
      }).get.each do |system|
        calendar = system.email
        next if !calendar || calendar.empty?
        system_calendars[calendar] = system
      end
    end

    # default to the current user if no params were passed
    system_calendars[user.email] = nil if allow_default && system_calendars.empty? && calendars.empty? && zones.empty? && system_ids.empty?

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
      case
      when (none = deny) && !(none & groups).empty?
        {false, Access::None}
      when (can_manage = manage) && !(can_manage & groups).empty?
        {true, Access::Manage}
      when (can_admin = admin) && !(can_admin & groups).empty?
        {true, Access::Admin}
      else
        {false, Access::None}
      end
    end
  end

  # https://docs.google.com/document/d/1OaZljpjLVueFitmFWx8xy8BT8rA2lITyPsIvSYyNNW8/edit#
  # See the section on user-permissions
  def check_access(groups : Array(String), check : Array(String))
    client = get_placeos_client.metadata
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
