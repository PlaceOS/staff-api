# Calendars, lists the user's calendars and checks room and people availability (free/busy) via the tenant's Office365 or Google calendar
class Calendars < Application
  base "/api/staff/v1/calendars"

  # =====================
  # Request Queue
  # =====================

  # queue requests on a per-user basis
  @[AC::Route::Filter(:around_action)]
  Application.add_request_queue

  @[AC::Route::Filter(:before_action)]
  private def ensure_tenant
    current_tenant
  end

  @[AC::Route::Filter(:before_action, except: [:index, :check_permission])]
  private def find_matching_calendars(
    @[AC::Param::Info(description: "a comma separated list of calendar ids (email addresses) to include; for room resource calendars prefer `system_ids`", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil,
    @[AC::Param::Info(description: "a comma separated list of zone ids (buildings or levels); all rooms (systems with a calendar email) in any of these zones are checked", example: "zone-123,zone-456")]
    zone_ids : String? = nil,
    @[AC::Param::Info(description: "a comma separated list of room system ids to check", example: "sys-1234,sys-5678")]
    system_ids : String? = nil,
    @[AC::Param::Info(description: "a comma separated list of room features, rooms found via `zone_ids` must have all of them", example: "whiteboard,vidconf")]
    features : String? = nil,
    @[AC::Param::Info("the minimum room capacity, applies to rooms found via `zone_ids`", example: "8")]
    capacity : Int32? = nil,
    @[AC::Param::Info(description: "only return bookable (true) or non-bookable (false) rooms found via `zone_ids`", example: "true")]
    bookable : Bool? = nil,
  )
    @matching_calendars = matching_calendar_ids(
      calendars, zone_ids, system_ids, features, capacity, bookable
    )
  end

  getter! matching_calendars : Hash(String, PlaceOS::Model::ControlSystem?)

  record Availability, id : String, system : PlaceOS::Model::ControlSystem? = nil, availability : Array(PlaceCalendar::Availability)? = nil do
    include JSON::Serializable
  end

  # Lists the calendars available to the current user in the tenant's calendar provider.
  @[AC::Route::GET("/")]
  def index : Array(PlaceCalendar::Calendar)
    client.list_calendars(user.email)
  end

  # Checks whether the current user can edit (create or modify events in) another user's calendar.
  # Always true for the user's own calendar. On Office365 this checks the calendar's permissions,
  # on Google it always returns false. Returns 404 if the calendar can't be looked up.
  @[AC::Route::GET("/:user_email/permission")]
  def check_permission(
    @[AC::Param::Info(description: "email or UPN of the calendar owner", example: "foo@domain.com")]
    user_email : String,
  ) : NamedTuple(can_edit: Bool)
    current_user_email = user.email.downcase
    target_email = user_email.downcase

    # User always has permission to their own calendar
    if current_user_email == target_email
      return {can_edit: true}
    end

    # Get Office365 client and call calendarPermissions API
    if client.client_id == :office365
      o365_client = client.calendar.as(PlaceCalendar::Office365).client
      cal_res = o365_client.get_calendar(mailbox: target_email)
      {can_edit: cal_res.can_edit? || false}
    else
      {can_edit: false}
    end
  rescue ex
    Log.warn(exception: ex) { "failed to check calendar permission for #{target_email}" }
    raise Error::NotFound.new(ex.message || {error: "Not Found"}.to_json)
  end

  # Finds which rooms or people are free for the whole period, use it to find an available room to book.
  # Specify candidates with `calendars`, `system_ids` and/or `zone_ids` (optionally filtered by `features`, `capacity`, `bookable`).
  # Returns only the calendars with no busy time overlapping the period, including the room's system details where known.
  # Returns 204 with an empty list if no candidate calendars were specified.
  # Use `free_busy` instead to see the actual busy times of each calendar.
  @[AC::Route::GET("/availability")]
  def availability(
    @[AC::Param::Info(description: "search period start as a unix epoch in seconds", example: "1661725146")]
    period_start : Int64,
    @[AC::Param::Info(description: "search period end as a unix epoch in seconds", example: "1661743123")]
    period_end : Int64,
    @[AC::Param::Info(description: "a comma separated list of calendar ids (email addresses) to include; for room resource calendars prefer `system_ids`", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil,
  ) : Array(Availability)
    # Grab the system emails
    candidates = matching_calendars.transform_keys &.downcase
    candidate_calendars = candidates.keys

    # Append calendars you might not have direct access too
    # As typically a staff member can see anothers availability
    all_calendars = Set.new((calendars || "").split(',').map(&.strip.downcase).reject(&.empty?))
    all_calendars.concat(candidate_calendars)
    calendars = all_calendars.to_a

    render :no_content, json: [] of Availability if calendars.empty?
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

  # Returns the free/busy schedule of each selected room or person over the period, use it to view schedules or find a common free time.
  # Specify candidates with `calendars`, `system_ids` and/or `zone_ids` (optionally filtered by `features`, `capacity`, `bookable`).
  # Every calendar is returned with its availability blocks (busy times outside the period are removed) and the room's system details where known.
  # The period must be at least 5 minutes long. Use `availability` instead to get just the calendars that are completely free.
  @[AC::Route::GET("/free_busy")]
  def free_busy(
    @[AC::Param::Info(description: "search period start as a unix epoch in seconds", example: "1661725146")]
    period_start : Int64,
    @[AC::Param::Info(description: "search period end as a unix epoch in seconds, must be at least 5 minutes after period_start", example: "1661743123")]
    period_end : Int64,
    @[AC::Param::Info(description: "a comma separated list of calendar ids (email addresses) to include; for room resource calendars prefer `system_ids`", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil,
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

    # this is done in the library now
    # availability_view_interval = [duration, Time::Span.new(minutes: 30)].min.total_minutes.to_i!
    busy = client.get_availability(user_email, calendars, period_start, period_end)

    # Remove busy times that are outside of the period
    busy.each do |status|
      status.availability.reject! do |avail|
        avail.status == PlaceCalendar::AvailabilityStatus::Busy &&
          ((avail.ends_at <= period_start) || (avail.starts_at >= period_end))
      end
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
