class Calendars < Application
  base "/api/staff/v1/calendars"

  def index
    render json: client.list_calendars(user.email)
  end

  get "/availability", :availability do
    # Grab the system emails
    candidates = matching_calendar_ids
    calendars = candidates.keys

    # Append calendars you might not have direct access too
    # As typically a staff member can see anothers availability
    all_calendars = Set.new((params["calendars"]? || "").split(',').map(&.strip.downcase).reject(&.empty?))
    all_calendars.concat(calendars)
    calendars = all_calendars.to_a
    render(json: [] of String) if calendars.empty?

    # perform availability request
    period_start = Time.unix(query_params["period_start"].to_i64)
    period_end = Time.unix(query_params["period_end"].to_i64)
    busy = client.get_availability(user.email, calendars, period_start, period_end)

    # Remove any rooms that have overlapping bookings
    busy.each { |status| calendars.delete(status.calendar.downcase) unless status.availability.empty? }

    # Return the results
    results = calendars.map { |email|
      if system = candidates[email]?
        {
          id:     email,
          system: system,
        }
      else
        {
          id: email,
        }
      end
    }

    render json: results
  end

  get "/free_busy", :free_busy do
    # Grab the system emails
    candidates = matching_calendar_ids
    calendars = candidates.keys

    # Append calendars you might not have direct access too
    # As typically a staff member can see anothers availability
    all_calendars = Set.new((params["calendars"]? || "").split(',').map(&.strip.downcase).reject(&.empty?))
    all_calendars.concat(calendars)
    calendars = all_calendars.to_a
    render(json: [] of String) if calendars.empty?

    # perform availability request
    period_start = Time.unix(query_params["period_start"].to_i64)
    period_end = Time.unix(query_params["period_end"].to_i64)
    busy = client.get_availability(user.email, calendars, period_start, period_end)

    results = busy.map { |details|
      if system = candidates[details.calendar]?
        {
          id:           details.calendar,
          system:       system,
          availability: details.availability,
        }
      else
        {
          id:           details.calendar,
          availability: details.availability,
        }
      end
    }
    render json: results
  end
end
