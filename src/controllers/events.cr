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
    placeos_client = get_placeos_client

    host = input_event.host || user.email

    system_id = input_event.system_id || input_event.system.try(&.id)
    if system_id
      begin
        system = placeos_client.systems.fetch(system_id)
      rescue _ex : ::PlaceOS::Client::API::Error
        head(:not_found)
      end
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
        placeos_client.root.signal("staff/event/changed", {
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
              guest.banned = attendee.banned || false
              guest.dangerous = attendee.dangerous || false
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
              placeos_client.root.signal("staff/guest/attending", {
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

  def update
    event_id = route_params["id"]
    changes = PlaceCalendar::Event.from_json(request.body.as(IO))

    placeos_client = get_placeos_client

    cal_id = if user_cal = query_params["calendar"]?
               found = get_user_calendars.reject { |cal| cal.id != user_cal }.first?
               head(:not_found) unless found
               user_cal
             elsif system_id = (query_params["system_id"]? || changes.system_id).presence
               begin
                 system = placeos_client.systems.fetch(system_id)
               rescue _ex : ::PlaceOS::Client::API::Error
                 head(:not_found)
               end
               sys_cal = system.email.presence
               head(:not_found) unless sys_cal
               sys_cal
             else
               head :bad_request
             end
    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    head(:not_found) unless event

    # User details
    user_email = user.email
    host = event.host || user_email

    # check permisions
    existing_attendees = event.attendees.try(&.map { |a| a.email }) || [] of String
    unless user_email == host || user_email.in?(existing_attendees) || host.in?(existing_attendees)
      # may be able to edit on behalf of the user
      head(:forbidden) unless system && !check_access(user.roles, system).none?
    end

    # Check if attendees need updating
    update_attendees = !changes.attendees.nil?
    attendees = changes.attendees.try(&.map { |a| a.email }) || existing_attendees

    # Ensure the host is configured to be attending the meeting and has accepted the meeting
    unless host.in?(attendees)
      host_attendee = PlaceCalendar::Event::Attendee.new(name: host, email: host, response_status: "accepted")
      host_attendee.visit_expected = true
      changes.attendees << host_attendee
    end

    attendees << cal_id
    attendees.uniq!

    # Attendees that need to be deleted:
    remove_attendees = existing_attendees - attendees

    zone = if tz = changes.timezone
             Time::Location.load(tz)
           elsif event_tz = event.timezone
             Time::Location.load(event_tz)
           else
             get_timezone
           end

    changes.event_start = changes.event_start.in(zone)
    changes.event_end = changes.event_end.not_nil!.in(zone)

    # TODO: Test change of room for o365
    # are we moving the event room?
    changing_room = system_id != (changes.system_id.presence || system_id)
    if changing_room
      new_system_id = changes.system_id.presence.not_nil!

      begin
        new_system = placeos_client.systems.fetch(new_system_id)
      rescue _ex : ::PlaceOS::Client::API::Error
        head(:not_found)
      end
      new_sys_cal = new_system.email.presence
      head(:not_found) unless new_sys_cal

      # Check this room isn't already invited
      head(:conflict) if existing_attendees.includes?(new_sys_cal)

      attendees.delete(cal_id)
      attendees << new_sys_cal
      update_attendees = true
      remove_attendees = [] of String

      # Remove old room from attendees
      attendees_without_old_room = changes.attendees.uniq.reject { |attendee| attendee.email == sys_cal }
      changes.attendees = attendees_without_old_room
      # Add the updated system attendee to the payload for update
      changes.attendees << PlaceCalendar::Event::Attendee.new(name: new_sys_cal, email: new_sys_cal)

      cal_id = new_sys_cal
      system = new_system
    else
      # If room is not changing and it is not an attendee, add it.
      if system && !changes.attendees.map { |a| a.email }.includes?(sys_cal)
        changes.attendees << PlaceCalendar::Event::Attendee.new(name: sys_cal.not_nil!, email: sys_cal.not_nil!)
      end
    end

    updated_event = client.update_event(user_id: host, event: changes, calendar_id: host)

    if system
      meta = if changing_room
               old_meta = EventMetadata.query.find({event_id: event.id})

               if old_meta
                 new_meta = EventMetadata.new
                 new_meta.ext_data = old_meta.ext_data
                 old_meta.delete
                 new_meta
               else
                 EventMetadata.new
               end
             else
               EventMetadata.query.find({event_id: event.id}) || EventMetadata.new
             end

      meta.system_id = system.id.not_nil!
      meta.event_id = event.id.not_nil!
      meta.event_start = changes.not_nil!.event_start.not_nil!.to_unix
      meta.event_end = changes.not_nil!.event_end.not_nil!.to_unix
      meta.resource_calendar = system.email.not_nil!
      meta.host_email = host

      if extension_data = changes.extension_data
        data = meta.ext_data.not_nil!.as_h
        # Updating extension data by merging into existing.
        extension_data.as_h.each { |key, value| data[key] = value }
        meta.ext_data = JSON.parse(data.to_json)
        meta.save!
      elsif changing_room || update_attendees
        meta.save!
      end

      # Grab the list of externals that might be attending
      if update_attendees
        existing_lookup = {} of String => Attendee
        existing = meta.attendees.to_a
        existing.each { |a| existing_lookup[a.email] = a } unless changing_room

        if !remove_attendees.empty?
          remove_attendees.each do |email|
            existing.select { |attend| attend.email == email }.each do |attend|
              existing_lookup.delete(attend.email)
              attend.delete
            end
          end
        end

        attending = changes.try &.attendees.try(&.reject { |attendee|
          # rejecting nil as we want to mark them as not attending where they might have otherwise been attending
          attendee.visit_expected.nil?
        })

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
              guest.banned = attendee.banned || false
              guest.dangerous = attendee.dangerous || false
            end

            if attendee_ext_data = attendee.extension_data
              guest.ext_data = attendee_ext_data
            end

            guest.save!

            # Create attendees
            attend = existing_lookup[email]? || Attendee.new
            if attend.persisted?
              previously_visiting = attend.visit_expected
            else
              previously_visiting = false
              attend.visit_expected = true
              attend.checked_in = false
            end

            attend.event_id = meta.id.not_nil!
            attend.guest_id = guest.id
            attend.save!

            if !previously_visiting
              spawn do
                sys = system.not_nil!

                placeos_client.root.signal("staff/guest/attending", {
                  action:         :meeting_update,
                  system_id:      sys.id,
                  event_id:       event_id,
                  host:           host,
                  resource:       sys.email,
                  event_summary:  updated_event.not_nil!.body,
                  event_starting: updated_event.not_nil!.event_start.not_nil!.to_unix,
                  attendee_name:  attendee.name,
                  attendee_email: attendee.email,
                })
              end
            end
          end
        end
      end

      # Update PlaceOS with an signal "staff/event/changed"
      spawn do
        sys = system.not_nil!
        placeos_client.root.signal("staff/event/changed", {
          action:    :update,
          system_id: sys.id,
          event_id:  event_id,
          host:      host,
          resource:  sys.email,
        })
      end

      render json: StaffApi::Event.augment(updated_event.not_nil!, system.not_nil!.email, system, meta)
    else
      render json: StaffApi::Event.augment(updated_event.not_nil!, host)
    end
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

  def destroy
    event_id = route_params["id"]
    notify_guests = query_params["notify"]? != "false"

    if user_cal = query_params["calendar"]?
      # Need to confirm the user can access this calendar
      found = get_user_calendars.reject { |cal| cal.id != user_cal }.first?
      head(:not_found) unless found

      # Delete the event
      client.delete_event(user_id: user.email, id: event_id, calendar_id: user_cal, notify: notify_guests)

      head :accepted
    elsif system_id = query_params["system_id"]?
      placeos_client = get_placeos_client

      # Need to grab the calendar associated with this system
      begin
        system = placeos_client.systems.fetch(system_id)
      rescue _ex : ::PlaceOS::Client::API::Error
        head(:not_found)
      end
      cal_id = system.email
      head(:not_found) unless cal_id

      EventMetadata.query.find({event_id: event_id}).try &.delete
      # Delete the event
      client.delete_event(user_id: user.email, id: event_id, calendar_id: cal_id, notify: notify_guests)

      head :accepted

      spawn do
        placeos_client.root.signal("staff/event/changed", {
          action:    :cancelled,
          system_id: system.id,
          event_id:  event_id,
          resource:  system.email,
        })
      end

      head :accepted
    end

    head :bad_request
  end

  get("/:id/guests", :guest_list) do
    event_id = route_params["id"]
    render(json: [] of Nil) if query_params["calendar"]?
    system_id = query_params["system_id"]?
    render :bad_request, json: {error: "missing system_id param"} unless system_id

    # Grab meeting metadata if it exists
    metadata = EventMetadata.query.find({event_id: event_id})
    render(json: [] of Nil) unless metadata

    # Find anyone who is attending
    visitors = metadata.attendees.to_a
    render(json: [] of Nil) if visitors.empty?

    # Grab the guest profiles if they exist
    guests = {} of String => Guest
    visitors.each { |visitor| guests[visitor.guest.email.not_nil!] = visitor.guest }

    # Merge the visitor data with guest profiles
    visitors = visitors.map { |visitor| attending_guest(visitor, guests[visitor.guest.email]?) }

    render json: visitors
  end

  post("/:id/guests/:guest_id/checkin", :guest_checkin) do
    event_id = route_params["id"]
    guest_email = route_params["guest_id"].downcase
    checkin = (query_params["state"]? || "true") == "true"

    system_id = query_params["system_id"]?
    render :bad_request, json: {error: "missing system_id param"} unless system_id

    guest = Guest.query.find({email: guest_email})
    eventmeta = EventMetadata.query.find({event_id: event_id})
    head(:not_found) if guest.nil? || eventmeta.nil?

    attendee = Attendee.query.find({guest_id: guest.id, event_id: eventmeta.not_nil!.id})
    if attendee
      attendee.checked_in = checkin
      attendee.save!

      guest_details = attendee.guest

      # Check the event is still on
      event = client.get_event(user.email, id: event_id, calendar_id: eventmeta.not_nil!.resource_calendar)
      head(:not_found) unless event && event.status != "cancelled"

      # Update PlaceOS with an signal "staff/guest/checkin"
      spawn do
        get_placeos_client.root.signal("staff/guest/checkin", {
          action:         :checkin,
          system_id:      system_id,
          event_id:       event_id,
          host:           eventmeta.not_nil!.host_email,
          resource:       eventmeta.not_nil!.resource_calendar,
          event_summary:  event.not_nil!.body,
          event_starting: eventmeta.not_nil!.event_start,
          attendee_name:  guest_details.name,
          attendee_email: guest_details.email,
        })
      end

      render json: attending_guest(attendee, attendee.guest)
    else
      head :not_found
    end
  end

  private def get_user_calendars
    client.list_calendars(user.email)
  end
end
