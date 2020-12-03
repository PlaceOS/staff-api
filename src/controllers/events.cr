class Events < Application
  base "/api/staff/v1/events"

  # Skip scope check for a single route
  skip_action :check_jwt_scope, only: [:show, :guest_checkin]

  def index
    period_start = Time.unix(query_params["period_start"].to_i64)
    period_end = Time.unix(query_params["period_end"].to_i64)

    calendars = matching_calendar_ids(allow_default: true)

    Log.context.set(calendar_size: calendars.size.to_s)
    render(json: [] of Nil) unless calendars.size > 0
    include_cancelled = query_params["include_cancelled"]? == "true"

    # Grab events in batches
    requests = [] of HTTP::Request
    mappings = calendars.map { |calendar_id, system|
      request = client.list_events_request(
        user.email,
        calendar_id,
        period_start: period_start,
        period_end: period_end,
        showDeleted: include_cancelled
      )
      requests << request
      {request, calendar_id, system}
    }

    responses = client.batch(user.email, requests)

    # Process the response (map requests back to responses)
    errors = 0
    results = [] of Tuple(String, PlaceOS::Client::API::Models::System?, PlaceCalendar::Event)
    mappings.each do |(request, calendar_id, system)|
      begin
        results.concat client.list_events(user.email, responses[request]).map { |event| {calendar_id, system, event} }
      rescue error
        errors += 1
        Log.warn(exception: error) { "error fetching events for #{calendar_id}" }
      end
    end
    response.headers["X-Calendar-Errors"] = errors.to_s if errors > 0

    # Grab any existing event metadata
    metadatas = {} of String => EventMetadata
    metadata_ids = [] of String
    results.map { |(_calendar_id, system, event)|
      if system
        metadata_ids << event.id.not_nil!
        metadata_ids << event.recurring_event_id.not_nil! if event.recurring_event_id && event.recurring_event_id != event.id
      end
    }
    metadata_ids.uniq!

    # Don't perform the query if there are no calendar entries
    if !metadata_ids.empty?
      data = EventMetadata.query.by_tenant(tenant.id).where { event_id.in?(metadata_ids) }
      data.each { |meta| metadatas[meta.event_id] = meta }
    end

    # return array of standardised events
    render json: results.map { |(calendar_id, system, event)|
      parent_meta = false
      metadata = metadatas[event.id]?
      if metadata.nil? && event.recurring_event_id
        metadata = metadatas[event.recurring_event_id]?
        parent_meta = true
      end
      StaffApi::Event.augment(event, calendar_id, system, metadata, parent_meta)
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
          ext_data:  input_event.extension_data,
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
        meta.tenant_id = tenant.id
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
              guest.tenant_id = tenant.id
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
            attend.tenant_id = tenant.id
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

    # Guests can update extension_data to indicate their order
    if user_token.scope.includes?("guest")
      guest_event_id, guest_system_id = user.roles

      head :forbidden unless changes.extension_data && event_id == guest_event_id && query_params["system_id"]? == guest_system_id
    end

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

    # Guests can only update the extension_data
    if user_token.scope.includes?("guest")
      meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.id})
      if meta.nil? && event.recurring_event_id
        if old_meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id})
          meta = EventMetadata.new
          meta.ext_data = old_meta.ext_data
        end
      end
      meta = meta || EventMetadata.new

      # Only assign values if we are creating metadata
      unless meta.persisted?
        meta.system_id = system_id.not_nil!
        meta.event_id = event.id.not_nil!
        meta.event_start = event.event_start.not_nil!.to_unix
        meta.event_end = event.event_end.not_nil!.to_unix
        meta.resource_calendar = system.not_nil!.email.not_nil!
        meta.host_email = event.host.not_nil!
        meta.tenant_id = tenant.id
      end

      if extension_data = changes.extension_data
        meta_ext_data = meta.not_nil!.ext_data
        data = meta_ext_data ? meta_ext_data.as_h : Hash(String, JSON::Any).new
        # Updating extension data by merging into existing.
        extension_data.as_h.each { |key, value| data[key] = value }
        # Needed for clear to assign the updated json correctly
        meta.ext_data_column.clear
        meta.ext_data = JSON.parse(data.to_json)
        meta.save!
      end

      render json: StaffApi::Event.augment(event, cal_id, system, meta)
    end

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
      attendees << host
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
      meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.id})

      # migrate the parent metadata to this event if not existing
      if meta.nil? && event.recurring_event_id
        if old_meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id})
          meta = EventMetadata.new
          meta.ext_data = old_meta.ext_data
        end
      end

      meta = meta || EventMetadata.new

      # Changing the room if applicable
      meta.system_id = system.id.not_nil!

      meta.event_id = event.id.not_nil!
      meta.event_start = changes.not_nil!.event_start.not_nil!.to_unix
      meta.event_end = changes.not_nil!.event_end.not_nil!.to_unix
      meta.resource_calendar = system.email.not_nil!
      meta.host_email = host
      meta.tenant_id = tenant.id

      if extension_data = changes.extension_data
        meta_ext_data = meta.not_nil!.ext_data
        data = meta_ext_data ? meta_ext_data.as_h : Hash(String, JSON::Any).new
        # Updating extension data by merging into existing.
        extension_data.as_h.each { |key, value| data[key] = value }
        # Needed for clear to assign the updated json correctly
        meta.ext_data_column.clear
        meta.ext_data = JSON.parse(data.to_json)
        meta.save!
      elsif changing_room || update_attendees
        meta.save!
      end

      # Grab the list of externals that might be attending
      if update_attendees || changing_room
        existing_lookup = {} of String => Attendee
        existing = meta.attendees.to_a
        existing.each { |a| existing_lookup[a.email] = a }

        if !remove_attendees.empty?
          remove_attendees.each do |email|
            existing.select { |attend| attend.guest.email == email }.each do |attend|
              existing_lookup.delete(attend.email)
              attend.delete
            end
          end
        end

        attending = changes.attendees.try(&.reject { |attendee|
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
              guest.tenant_id = tenant.id
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
              attend.tenant_id = tenant.id
            end

            attend.event_id = meta.id.not_nil!
            attend.guest_id = guest.id
            attend.save!

            if !previously_visiting || changing_room
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
        elsif changing_room
          existing.each do |attend|
            next unless attend.visit_expected
            spawn do
              sys = system.not_nil!
              guest = attend.guest

              placeos_client.root.signal("staff/guest/attending", {
                action:         :meeting_update,
                system_id:      sys.id,
                event_id:       event_id,
                host:           host,
                resource:       sys.email,
                event_summary:  updated_event.not_nil!.body,
                event_starting: updated_event.not_nil!.event_start.not_nil!.to_unix,
                attendee_name:  guest.name,
                attendee_email: guest.email,
              })
            end
          end
        end
      end

      # Reloading meta with attendees and guests to avoid n+1
      eventmeta = EventMetadata.query.by_tenant(tenant.id).with_attendees(&.with_guest).find({event_id: event_id})

      # Update PlaceOS with an signal "staff/event/changed"
      spawn do
        sys = system.not_nil!
        placeos_client.root.signal("staff/event/changed", {
          action:    :update,
          system_id: sys.id,
          event_id:  event_id,
          host:      host,
          resource:  sys.email,
          ext_data:  eventmeta.try &.ext_data,
        })
      end

      render json: StaffApi::Event.augment(updated_event.not_nil!, system.not_nil!.email, system, eventmeta)
    else
      render json: StaffApi::Event.augment(updated_event.not_nil!, host)
    end
  end

  def show
    event_id = route_params["id"]
    placeos_client = get_placeos_client

    # Guest access
    if user_token.scope.includes?("guest")
      guest_event_id, system_id = user.roles
      guest_email = user.email.downcase

      head :forbidden unless event_id == guest_event_id

      # grab the calendar id
      begin
        calendar_id = placeos_client.systems.fetch(system_id).email.presence
      rescue _ex : ::PlaceOS::Client::API::Error
        head(:not_found)
      end
      head(:not_found) unless calendar_id

      # Get the event using the admin account
      event = client.get_event(user.email, id: event_id, calendar_id: calendar_id)
      head(:not_found) unless event

      eventmeta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event_id})
      guest = Guest.query.by_tenant(tenant.id).find({email: guest_email})
      head(:not_found) unless guest

      attendee = Attendee.query.by_tenant(tenant.id).find({guest_id: guest.id, event_id: eventmeta.try(&.id)})

      # check recurring master
      if attendee.nil? && event.recurring_event_id.presence && event.recurring_event_id != event.id
        master_metadata_id = event.recurring_event_id
        eventmeta = EventMetadata.query.by_tenant(tenant.id).find({event_id: master_metadata_id})
        attendee = Attendee.query.by_tenant(tenant.id).find({guest_id: guest.id, event_id: eventmeta.try(&.id)})
      end
      head(:not_found) unless eventmeta

      if attendee
        begin
          system = placeos_client.systems.fetch(system_id)
        rescue _ex : ::PlaceOS::Client::API::Error
          head(:not_found)
        end

        render json: StaffApi::Event.augment(event.not_nil!, eventmeta.not_nil!.resource_calendar, system, eventmeta)
      else
        head :not_found
      end
    end

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
        system = placeos_client.systems.fetch(system_id)
      rescue _ex : ::PlaceOS::Client::API::Error
        head(:not_found)
      end
      cal_id = system.email
      head(:not_found) unless cal_id

      event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
      head(:not_found) unless event

      parent_meta = false
      metadata = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.id})
      if event.recurring_event_id && event.id != event.recurring_event_id
        metadata = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id})
        parent_meta = true
      end
      render json: StaffApi::Event.augment(event.not_nil!, cal_id, system, metadata, parent_meta)
    end

    head :bad_request
  end

  def destroy
    event_id = route_params["id"]
    notify_guests = query_params["notify"]? != "false"
    placeos_client = get_placeos_client

    cal_id = if user_cal = query_params["calendar"]?
               found = get_user_calendars.reject { |cal| cal.id != user_cal }.first?
               head(:not_found) unless found
               user_cal
             elsif system_id = query_params["system_id"]?
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
      # may be able to delete on behalf of the user
      head(:forbidden) unless system && !check_access(user.roles, system).none?
    end

    client.delete_event(user_id: user.email, id: event_id, calendar_id: cal_id, notify: notify_guests)

    if system
      EventMetadata.query.by_tenant(tenant.id).find({event_id: event_id}).try &.delete

      spawn do
        placeos_client.root.signal("staff/event/changed", {
          action:    :cancelled,
          system_id: system.not_nil!.id,
          event_id:  event_id,
          resource:  system.not_nil!.email,
        })
      end
    end

    head :accepted
  end

  #
  # Event Approval / Rejection
  #
  post "/:id/approve", :approve do
    update_status("accepted")
  end

  post "/:id/reject", :reject do
    update_status("declined")
  end

  def update_status(status)
    event_id = route_params["id"]
    system_id = query_params["system_id"]

    # Check this system has an associated resource
    begin
      system = get_placeos_client.systems.fetch(system_id)
    rescue _ex : ::PlaceOS::Client::API::Error
      head(:not_found)
    end
    cal_id = system.email
    head(:not_found) unless cal_id

    # Check the event was in the calendar
    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    head(:not_found) unless event

    # Existing attendees without system
    attendees = event.attendees.uniq.reject { |attendee| attendee.email.downcase == cal_id.downcase }
    # Adding back system with correct status
    attendees << PlaceCalendar::Event::Attendee.new(name: cal_id, email: cal_id, response_status: status)

    event.not_nil!.attendees = attendees

    # Update the event (user must be a resource approver)
    updated_event = client.update_event(user_id: user.email, event: event, calendar_id: cal_id)

    # Return the full event details
    metadata = EventMetadata.query.by_tenant(tenant.id).find({event_id: event_id})

    render json: StaffApi::Event.augment(updated_event.not_nil!, system.email, system, metadata)
  end

  #
  # Event Guest management
  #
  get("/:id/guests", :guest_list) do
    event_id = route_params["id"]
    render(json: [] of Nil) if query_params["calendar"]?
    system_id = query_params["system_id"]?
    render :bad_request, json: {error: "missing system_id param"} unless system_id

    # Grab meeting metadata if it exists
    parent_meta = false
    metadata = EventMetadata.query.by_tenant(tenant.id).find({event_id: event_id})
    if metadata.nil?
      if cal_id = get_placeos_client.systems.fetch(system_id).email
        event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
        metadata = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id}) if event && event.recurring_event_id
        parent_meta = !!metadata
      end
    end
    render(json: [] of Nil) unless metadata

    # Find anyone who is attending
    visitors = metadata.attendees.to_a
    render(json: [] of Nil) if visitors.empty?

    # Grab the guest profiles if they exist
    guests = {} of String => Guest
    visitors.each { |visitor| guests[visitor.guest.email.not_nil!] = visitor.guest }

    # Merge the visitor data with guest profiles
    visitors = visitors.map { |visitor| attending_guest(visitor, guests[visitor.guest.email]?, parent_meta) }

    render json: visitors
  end

  post("/:id/guests/:guest_id/checkin", :guest_checkin) do
    checkin = (query_params["state"]? || "true") == "true"
    event_id = route_params["id"]
    guest_email = route_params["guest_id"].downcase

    if user_token.scope.includes?("guest")
      guest_event_id, system_id = user.roles
      guest_token_email = user.email.downcase

      head :forbidden unless event_id == guest_event_id && guest_email == guest_token_email
    else
      system_id = query_params["system_id"]?
      render :bad_request, json: {error: "missing system_id param"} unless system_id
    end

    guest = Guest.query.by_tenant(tenant.id).find({email: guest_email})
    eventmeta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event_id})
    head(:not_found) if guest.nil?

    if eventmeta.nil?
      if cal_id = get_placeos_client.systems.fetch(system_id).email
        event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
        head(:not_found) if event.nil?
        eventmeta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id}) if event && event.recurring_event_id
        EventMetadata.migrate_recurring_metadata(system_id, event.not_nil!, eventmeta) if event && eventmeta
      end
    end

    attendee = Attendee.query.by_tenant(tenant.id).find({guest_id: guest.id, event_id: eventmeta.not_nil!.id})
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
          checkin:        checkin,
          system_id:      system_id,
          event_id:       event_id,
          host:           eventmeta.not_nil!.host_email,
          resource:       eventmeta.not_nil!.resource_calendar,
          event_summary:  event.not_nil!.body,
          event_starting: eventmeta.not_nil!.event_start,
          attendee_name:  guest_details.name,
          attendee_email: guest_details.email,
          ext_data:       eventmeta.try &.ext_data,
        })
      end

      render json: attending_guest(attendee, attendee.guest)
    else
      head :not_found
    end
  end
end
