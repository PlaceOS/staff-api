class Events < Application
  base "/api/staff/v1/events"

  def index
    period_start = Time.unix(query_params["period_start"].to_i64)
    period_end = Time.unix(query_params["period_end"].to_i64)

    calendars = matching_calendar_ids
    render(json: [] of Nil) unless calendars.size > 0

    include_cancelled = query_params["include_cancelled"]? == "true"

    # Grab events in parallel
    responses = Promise.all(calendars.map { |calendar_id, system|
      Promise.defer {
        events = client.list_events(
          user.email,
          calendar_id,
          period_start: period_start,
          period_end: period_end,
          showDeleted: include_cancelled
        ).map { |event| {calendar_id, system, event} }

        # no error, the cal id and the list of the events
        {"", calendar_id, events}
      }.catch { |error|
        sys_name = system.try(&.name)
        calendar_id = sys_name ? "#{sys_name} (#{calendar_id})" : calendar_id
        {error.message || "", calendar_id, [] of Tuple(String, PlaceOS::Client::API::Models::System?, PlaceCalendar::Event)}
      }
    }).get

    # if there are any errors let's log them and expose them via the API
    # done outside the promise so we have all the tagging associated with this fiber
    calendar_errors = [] of String
    responses.select { |result| result[0].presence }.each do |error|
      calendar_id = error[1]
      calendar_errors << calendar_id
      Log.warn { "error fetching events for #{calendar_id}: #{error[0]}" }
    end
    response.headers["X-Calendar-Errors"] = calendar_errors unless calendar_errors.empty?

    # return the valid results
    results = responses.map { |result| result[2] }.flatten

    # Grab any existing event metadata
    metadatas = {} of String => EventMetadata
    metadata_ids = results.map { |(_calendar_id, system, event)|
      system.nil? ? nil : event.id
    }.compact

    # Don't perform the query if there are no calendar entries
    if !metadata_ids.empty?
      data = EventMetadata.query.where { event_id.in?(metadata_ids) }
      data.each { |meta| metadatas[meta.event_id] = meta }
    end

    # return array of standardised events
    render json: results.map { |(calendar_id, system, event)|
      StaffApi::Event.compose(event, calendar_id, system, metadatas[event.id]?)
    }
  end

  def show
    event_id = route_params["id"]
    if user_cal = query_params["calendar"]?
      # Need to confirm the user can access this calendar
      found = get_user_calendars.reject { |cal| cal.id != user_cal }.first?
      head(:not_found) unless found

      # Grab the event details
      event = client.get_event(user.email, id: event_id, calendar_id: user_cal)
      head(:not_found) unless event

      render json: StaffApi::Event.compose(event.not_nil!, user_cal)
    elsif system_id = query_params["system_id"]?
      # Need to grab the calendar associated with this system
      begin
        system = get_placeos_client.systems.fetch(system_id)
      rescue _ex : ::PlaceOS::Client::API::Error
        head(:not_found)
      end
      cal_id = system.email
      head(:not_found) unless cal_id

      event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
      head(:not_found) unless event

      metadata = EventMetadata.query.find({event_id: event.id})
      render json: StaffApi::Event.compose(event.not_nil!, cal_id, system, metadata)
    end

    head :bad_request
  end

  private def get_user_calendars
    client.list_calendars(user.email)
  end
end
