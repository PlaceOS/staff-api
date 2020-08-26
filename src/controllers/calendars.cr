class Calendars < Application
  base "/api/staff/v1/calendars"

  def index
    render json: client.list_calendars(user.email)
  end

  get "/availability", :availability do
    candidates = matching_calendar_ids
    calendars = candidates.keys
    render(json: [] of String) if calendars.empty?

    # perform availability request
    period_start = Time.unix(query_params["period_start"].to_i64)
    period_end = Time.unix(query_params["period_end"].to_i64)
    busy = client.get_availability(user.email, calendars, period_start, period_end)

    # Remove any rooms that have overlapping bookings
    busy.each { |status| candidates.delete(status.calendar) unless status.availability.empty? }

    # Return the results
    results = candidates.map { |email, system|
      {
        id: email,
        system: system
      }
    }
    render json: results
  end

end
