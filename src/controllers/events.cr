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
      StaffApi::Event.augment(event, calendar_id, system, metadatas[event.id]?)
    }
  end

  def create
    input_event = PlaceCalendar::Event.from_json(request.body.as(IO))

    host = input_event.host || user.email

    system_id = input_event.system_id || input_event.system.try(&.id)
    if system_id
      system = get_placeos_client.systems.fetch(system_id)
      system_email = system.email.presence.not_nil!
      system_attendee = PlaceCalendar::Event::Attendee.new(name: system_email, email: system_email)
      input_event.attendees << system_attendee
    end

    # Ensure the host is configured to be attending the meeting and has accepted the meeting
    attendees = input_event.attendees.uniq.reject { |attendee| attendee.email == host }
    input_event.attendees = attendees
    host_attendee = PlaceCalendar::Event::Attendee.new(name: host, email: host, response_status: "accepted")
    host_attendee.visit_expected = true
    input_event.attendees << host_attendee

    # Default to system timezone if not passed in
    zone = input_event.timezone ? Time::Location.load(input_event.timezone.not_nil!) : get_timezone

    input_event.event_start = input_event.event_start.in(zone)
    input_event.event_end = input_event.event_end.not_nil!.in(zone)

    created_event = client.create_event(user_id: host, event: input_event, calendar_id: host)

    # Update PlaceOS with an signal "/staff/event/changed"
    if system && created_event
      sys = system.not_nil!

      # Grab the list of externals that might be attending
      attending = input_event.attendees.try(&.select { |attendee|
        attendee.visit_expected
      })

      spawn do
        get_placeos_client.root.signal("staff/event/changed", {
          action:    :create,
          system_id: input_event.system_id,
          event_id:  created_event.not_nil!.id,
          host:      host,
          resource:  sys.email,
        })
      end

      # Save custom data
      ext_data = input_event.extension_data
      if ext_data || (attending && !attending.empty?)
        meta = EventMetadata.new
        meta.system_id = sys.id.not_nil!
        meta.event_id = created_event.not_nil!.id.not_nil!
        meta.event_start = created_event.not_nil!.event_start.not_nil!.to_unix
        meta.event_end = created_event.not_nil!.event_end.not_nil!.to_unix
        meta.resource_calendar = sys.email.not_nil!
        meta.host_email = host
        meta.ext_data = ext_data
        meta.save!

        Log.info { "saving extension data for event #{created_event.not_nil!.id} in #{sys.id}" }

        if attending
          # Create guests
          attending.each do |attendee|
            email = attendee.email.strip.downcase

            existing_guest = Guest.query.find({email: email})
            if existing_guest
              guest = existing_guest
            else
              guest = Guest.new
              guest.email = email
              guest.name = attendee.name
              guest.preferred_name = attendee.preferred_name
              guest.phone = attendee.phone
              guest.organisation = attendee.organisation
              guest.photo = attendee.photo
              guest.notes = attendee.notes
              guest.banned = false
              guest.dangerous = false
            end

            if attendee_ext_data = attendee.extension_data
              guest.ext_data = attendee_ext_data
            end

            guest.save!

            # Create attendees
            attend = Attendee.new
            attend.event_id = meta.id.not_nil!
            attend.guest_id = guest.id
            attend.visit_expected = true
            attend.checked_in = false
            attend.save!

            spawn do
              get_placeos_client.root.signal("staff/guest/attending", {
                action:         :meeting_created,
                system_id:      sys.id,
                event_id:       created_event.not_nil!.id,
                host:           host,
                resource:       sys.email,
                event_summary:  created_event.not_nil!.body,
                event_starting: created_event.not_nil!.event_start.not_nil!.to_unix,
                attendee_name:  attendee.name,
                attendee_email: attendee.email,
              })
            end
          end
        end

        render json: StaffApi::Event.augment(created_event.not_nil!, sys.email, sys, meta)
      end

      Log.info { "no extension data for event #{created_event.not_nil!.id} in #{sys.id}, #{ext_data}" }

      render json: StaffApi::Event.augment(created_event.not_nil!, sys.email, sys)
    end

    Log.info { "no system provided for event #{created_event.not_nil!.id}" }
    render json: StaffApi::Event.augment(created_event.not_nil!, host)
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

      render json: StaffApi::Event.augment(event.not_nil!, user_cal)
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
      render json: StaffApi::Event.augment(event.not_nil!, cal_id, system, metadata)
    end

    head :bad_request
  end

  private def get_user_calendars
    client.list_calendars(user.email)
  end
end
