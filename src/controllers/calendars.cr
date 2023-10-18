class Calendars < Application
  base "/api/staff/v1/calendars"

  @[AC::Route::Filter(:before_action, except: [:index])]
  private def find_matching_calendars(
    @[AC::Param::Info(description: "a comma seperated list of calendar ids, recommend using `system_id` for resource calendars", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil,
    @[AC::Param::Info(description: "a comma seperated list of zone ids", example: "zone-123,zone-456")]
    zone_ids : String? = nil,
    @[AC::Param::Info(description: "a comma seperated list of event spaces", example: "sys-1234,sys-5678")]
    system_ids : String? = nil,
    @[AC::Param::Info(description: "a comma seperated list of room features", example: "whiteboard,vidconf")]
    features : String? = nil,
    @[AC::Param::Info("the minimum capacity required for an event space", example: "8")]
    capacity : Int32? = nil,
    @[AC::Param::Info(description: "only search for bookable or non-bookable rooms", example: "true")]
    bookable : Bool? = nil
  )
    @matching_calendars = matching_calendar_ids(
      calendars, zone_ids, system_ids, features, capacity, bookable
    )
  end

  getter! matching_calendars : Hash(String, PlaceOS::Client::API::Models::System?)

  record Availability, id : String, system : PlaceOS::Client::API::Models::System? = nil, availability : Array(PlaceCalendar::Availability)? = nil do
    include JSON::Serializable
  end

  # lists the users default calendars
  @[AC::Route::GET("/")]
  def index : Array(PlaceCalendar::Calendar)
    client.list_calendars(user.email)
  end

  # checks for availability of matched calendars, returns a list of calendars with availability
  @[AC::Route::GET("/availability")]
  def availability(
    @[AC::Param::Info(description: "search period start as a unix epoch", example: "1661725146")]
    period_start : Int64,
    @[AC::Param::Info(description: "search period end as a unix epoch", example: "1661743123")]
    period_end : Int64,
    @[AC::Param::Info(description: "a comma seperated list of calendar ids, recommend using `system_id` for resource calendars", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil
  ) : Array(Availability)
    # Grab the system emails
    candidates = matching_calendars.transform_keys &.downcase
    candidate_calendars = candidates.keys

    # Append calendars you might not have direct access too
    # As typically a staff member can see anothers availability
    all_calendars = Set.new((calendars || "").split(',').map(&.strip.downcase).reject(&.empty?))
    all_calendars.concat(candidate_calendars)
    calendars = all_calendars.to_a
    return [] of Availability if calendars.empty?

    # perform availability request
    period_start = Time.unix(period_start)
    period_end = Time.unix(period_end)
    user_email = tenant.which_account(user.email)
    busy = client.get_availability(user_email, calendars, period_start, period_end)

    # Remove any rooms that have overlapping bookings
    busy.each do |status|
      status.availability.each do |avail|
        if avail.status == PlaceCalendar::AvailabilityStatus::Busy && (period_start < avail.ends_at) && (period_end > avail.starts_at)
          calendars.delete(status.calendar.downcase)
        end
      end
    end

    # Return the results
    calendars.map { |email|
      if system = candidates[email]?
        Availability.new(id: email, system: system)
      else
        Availability.new(id: email)
      end
    }
  end

  # Finds the busy times in the period provided on the selected calendars.
  # Returns the calendars that have meetings overlapping provided period
  @[AC::Route::GET("/free_busy")]
  def free_busy(
    @[AC::Param::Info(description: "search period start as a unix epoch", example: "1661725146")]
    period_start : Int64,
    @[AC::Param::Info(description: "search period end as a unix epoch", example: "1661743123")]
    period_end : Int64,
    @[AC::Param::Info(description: "a comma seperated list of calendar ids, recommend using `system_id` for resource calendars", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil
  ) : Array(Availability)
    # Grab the system emails
    candidates = matching_calendars.transform_keys &.downcase
    candidate_calendars = candidates.keys

    # Append calendars you might not have direct access too
    # As typically a staff member can see anothers availability
    all_calendars = Set.new((calendars || "").split(',').map(&.strip.downcase).reject(&.empty?))
    all_calendars.concat(candidate_calendars)
    calendars = all_calendars.to_a
    return [] of Availability if calendars.empty?

    # perform availability request
    period_start = Time.unix(period_start)
    period_end = Time.unix(period_end)
    duration = period_end - period_start
    raise AC::Route::Param::ValueError.new("free/busy availability intervals must be greater than 5 minutes", "period_end") if duration.total_minutes < 5

    user_email = tenant.which_account(user.email)
    availability_view_interval = [duration, Time::Span.new(minutes: 30)].min.total_minutes.to_i!
    busy = client.get_availability(user_email, calendars, period_start, period_end, view_interval: availability_view_interval)

    # Remove busy times that are outside of the period
    busy.each do |status|
      new_availability = [] of PlaceCalendar::Availability
      status.availability.each do |avail|
        next if avail.status == PlaceCalendar::AvailabilityStatus::Busy &&
                (period_start <= avail.ends_at) && (period_end >= avail.starts_at)
        new_availability << avail
      end
      status.availability = new_availability
    end

    busy.map { |details|
      if system = candidates[details.calendar]?
        Availability.new(id: details.calendar, system: system, availability: details.availability)
      else
        Availability.new(id: details.calendar, availability: details.availability)
      end
    }
  end
end
