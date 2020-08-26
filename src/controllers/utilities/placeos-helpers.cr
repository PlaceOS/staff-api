require "placeos"
require "promise"

# Helper to interact with PlaceOS API
module Utils::PlaceOSHelpers
  # Base URL of the PlaceOS instance we are interacting with
  PLACE_URI = App::PLACE_URI

  @placeos_client : PlaceOS::Client? = nil

  def get_placeos_client : PlaceOS::Client
    @placeos_client ||= PlaceOS::Client.from_environment_user
  end

  # Get the list of local calendars this user has access to
  def get_user_calendars
    client.list_calendars(user.email)
  end

  class CalendarSelection < Params
    attribute calendars : String
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
    calendars = Set.new((args.calendars || "").split(',').map(&.strip).reject(&.empty?))
    user_calendars = Set.new(client.list_calendars(user.email).compact_map(&.id))
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
end
