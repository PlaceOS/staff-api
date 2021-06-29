class Events < Application
  base "/api/staff/v1/events"

  # Skip scope check for a single route
  skip_action :check_jwt_scope, only: [:show, :guest_checkin]

  # ameba:disable Metrics/CyclomaticComplexity
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
    ical_uids = [] of String
    results.map { |(_calendar_id, system, event)|
      if system
        metadata_ids << event.id.not_nil!
        ical_uids << event.ical_uid.not_nil!
        # TODO:: how to deal with recurring events in Office365 where ical_uid is also different for each recurrance
        metadata_ids << event.recurring_event_id.not_nil! if event.recurring_event_id && event.recurring_event_id != event.id
      end
    }

    metadata_ids.uniq!

    # Don't perform the query if there are no calendar entries
    if !metadata_ids.empty?
      EventMetadata.query.by_tenant(tenant.id).where { event_id.in?(metadata_ids) }.each { |meta|
        metadatas[meta.event_id] = meta
      }
    end

    # Metadata is stored against a resource calendar which in office365 can only
    # be matched by the `ical_uid`
    if (client.client_id == :office365) && ical_uids.uniq! && !ical_uids.empty?
      EventMetadata.query.by_tenant(tenant.id).where { ical_uid.in?(ical_uids) }.each { |meta|
        metadatas[meta.ical_uid] = meta
      }
    end

    # return array of standardised events
    render json: results.map { |(calendar_id, system, event)|
      parent_meta = false
      metadata = metadatas[event.id]?
      if metadata.nil? && event.recurring_event_id
        metadata = metadatas[event.recurring_event_id]?
        parent_meta = true if metadata
      end
      # Workaround for Office365 where ical_uid is unique for each occurance and event_id is different in each calendar
      metadata = metadata || metadatas[event.ical_uid]? if client.client_id == :office365
      StaffApi::Event.augment(event, calendar_id, system, metadata, parent_meta)
    }
  end

  # ameba:disable Metrics/CyclomaticComplexity
  def create
    input_event = PlaceCalendar::Event.from_json(request.body.as(IO))
    placeos_client = get_placeos_client

    host = input_event.host || user.email

    system_id = input_event.system_id || input_event.system.try(&.id)
    if system_id
      system = placeos_client.systems.fetch(system_id)
      system_email = system.email.presence.not_nil!
      system_attendee = PlaceCalendar::Event::Attendee.new(name: system.display_name.presence || system.name, email: system_email, resource: true)
      input_event.attendees << system_attendee
    end

    # Ensure the host is configured to be attending the meeting and has accepted the meeting
    attendees = input_event.attendees.uniq.reject { |attendee| attendee.email == host }
    input_event.attendees = attendees
    host_attendee = PlaceCalendar::Event::Attendee.new(name: host, email: host, response_status: "accepted")
    host_attendee.visit_expected = true
    input_event.attendees << host_attendee

    # Default to system timezone if not passed in
    zone = input_event.timezone.presence ? Time::Location.load(input_event.timezone.not_nil!) : get_timezone

    input_event.event_start = input_event.event_start.in(zone)
    input_event.event_end = input_event.event_end.not_nil!.in(zone)

    created_event = client.create_event(user_id: host, event: input_event, calendar_id: host).not_nil!

    # Update PlaceOS with an signal "/staff/event/changed"
    if system
      sys = system.not_nil!

      # Grab the list of externals that might be attending
      attending = input_event.attendees.try(&.select { |attendee|
        attendee.visit_expected
      })

      spawn do
        placeos_client.root.signal("staff/event/changed", {
          action:    :create,
          system_id: input_event.system_id,
          event_id:  created_event.id,
          host:      host,
          resource:  sys.email,
          ext_data:  input_event.extension_data,
        })
      end

      # Save custom data
      ext_data = input_event.extension_data
      if ext_data || (attending && !attending.empty?)
        meta = EventMetadata.create!({
          system_id:           sys.id.not_nil!,
          event_id:            created_event.id.not_nil!,
          recurring_master_id: (created_event.recurring_event_id || created_event.id if created_event.recurring),
          event_start:         created_event.event_start.not_nil!.to_unix,
          event_end:           created_event.event_end.not_nil!.to_unix,
          resource_calendar:   sys.email.not_nil!,
          host_email:          host,
          ext_data:            ext_data,
          tenant_id:           tenant.id,
          ical_uid:            created_event.ical_uid.not_nil!,
        })

        Log.info { "saving extension data for event #{created_event.id} in #{sys.id}" }

        if attending
          # Create guests
          attending.each do |attendee|
            email = attendee.email.strip.downcase

            guest = if existing_guest = Guest.query.find({email: email})
                      existing_guest.name = attendee.name if existing_guest.name != attendee.name
                      existing_guest
                    else
                      Guest.new({
                        email:          email,
                        name:           attendee.name,
                        preferred_name: attendee.preferred_name,
                        phone:          attendee.phone,
                        organisation:   attendee.organisation,
                        photo:          attendee.photo,
                        notes:          attendee.notes,
                        banned:         attendee.banned || false,
                        dangerous:      attendee.dangerous || false,
                        tenant_id:      tenant.id,
                      })
                    end

            if attendee_ext_data = attendee.extension_data
              guest.ext_data = attendee_ext_data
            end
            guest.save!

            # Create attendees
            Attendee.create!({
              event_id:       meta.id.not_nil!,
              guest_id:       guest.id,
              visit_expected: true,
              checked_in:     false,
              tenant_id:      tenant.id,
            })

            spawn do
              placeos_client.root.signal("staff/guest/attending", {
                action:         :meeting_created,
                system_id:      sys.id,
                event_id:       created_event.id,
                host:           host,
                resource:       sys.email,
                event_summary:  created_event.body,
                event_starting: created_event.event_start.not_nil!.to_unix,
                attendee_name:  attendee.name,
                attendee_email: attendee.email,
              })
            end
          end
        end

        render json: StaffApi::Event.augment(created_event, sys.email, sys, meta)
      end

      Log.info { "no extension data for event #{created_event.id} in #{sys.id}, #{ext_data}" }
      render json: StaffApi::Event.augment(created_event, sys.email, sys)
    end

    Log.info { "no system provided for event #{created_event.id}" }
    render json: StaffApi::Event.augment(created_event, host)
  end

  # ameba:disable Metrics/CyclomaticComplexity
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
               system = placeos_client.systems.fetch(system_id)
               sys_cal = system.email.presence
               head(:not_found) unless sys_cal
               sys_cal
             else
               head :bad_request
             end
    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    head(:not_found) unless event

    # ensure we have the host event details
    if client.client_id == :office365 && event.host != cal_id
      event = get_hosts_event(event)
      event_id = event.id.not_nil!
    end

    # Guests can only update the extension_data
    if user_token.scope.includes?("guest")
      # We expect the metadata to exist when a guest is accessing
      meta = get_migrated_metadata(event, system_id.not_nil!).not_nil!

      if extension_data = changes.extension_data
        meta_ext_data = meta.ext_data
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
      head(:forbidden) if !(system && !check_access(user.roles, [system.id] + system.zones).none?)
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

      new_system = placeos_client.systems.fetch(new_system_id)
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
      changes.attendees << PlaceCalendar::Event::Attendee.new(name: new_system.display_name.presence || new_system.name, email: new_sys_cal, resource: true)

      new_sys_cal # cal_id
      system = new_system
    else
      # If room is not changing and it is not an attendee, add it.
      if system && !changes.attendees.map { |a| a.email }.includes?(sys_cal)
        changes.attendees << PlaceCalendar::Event::Attendee.new(name: system.display_name.presence || system.name, email: sys_cal.not_nil!, resource: true)
      end
    end

    updated_event = client.update_event(user_id: host, event: changes, calendar_id: host).not_nil!

    if system
      meta = get_migrated_metadata(event, system_id.not_nil!) || EventMetadata.new

      # Changing the room if applicable
      meta.system_id = system.id.not_nil!

      meta.event_id = event.id.not_nil!
      meta.ical_uid = updated_event.ical_uid.not_nil!
      meta.recurring_master_id = updated_event.recurring_event_id || updated_event.id if updated_event.recurring
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

        # rejecting nil as we want to mark them as not attending where they might have otherwise been attending
        attending = changes.attendees.try(&.reject { |attendee| attendee.visit_expected.nil? })

        if attending
          # Create guests
          attending.each do |attendee|
            email = attendee.email.strip.downcase

            guest = if existing_guest = Guest.query.find({email: email})
                      existing_guest
                    else
                      Guest.new({
                        email:          email,
                        name:           attendee.name,
                        preferred_name: attendee.preferred_name,
                        phone:          attendee.phone,
                        organisation:   attendee.organisation,
                        photo:          attendee.photo,
                        notes:          attendee.notes,
                        banned:         attendee.banned || false,
                        dangerous:      attendee.dangerous || false,
                        tenant_id:      tenant.id,
                      })
                    end

            if attendee_ext_data = attendee.extension_data
              guest.ext_data = attendee_ext_data
            end

            guest.save!

            # Create attendees
            attend = existing_lookup[email]? || Attendee.new

            previously_visiting = if attend.persisted?
                                    attend.visit_expected
                                  else
                                    attend.set({
                                      visit_expected: true,
                                      checked_in:     false,
                                      tenant_id:      tenant.id,
                                    })
                                    false
                                  end

            attend.update!({
              event_id: meta.id.not_nil!,
              guest_id: guest.id,
            })

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
      eventmeta = EventMetadata.query.by_tenant(tenant.id).with_attendees(&.with_guest).find({event_id: event_id, system_id: system.not_nil!.id.not_nil!})

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
      calendar_id = placeos_client.systems.fetch(system_id).email.presence
      head(:not_found) unless calendar_id

      guest = Guest.query.by_tenant(tenant.id).find!({email: guest_email})

      # Get the event using the admin account
      event = client.get_event(user.email, id: event_id, calendar_id: calendar_id)
      head(:not_found) unless event

      # ensure we have the host event details
      if client.client_id == :office365 && event.host != calendar_id
        event = get_hosts_event(event)
        event_id = event.id
      end

      eventmeta = get_event_metadata(event, system_id)
      head(:not_found) unless eventmeta

      if Attendee.query.by_tenant(tenant.id).find({guest_id: guest.id, event_id: eventmeta.id})
        system = placeos_client.systems.fetch(system_id)
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
      system = placeos_client.systems.fetch(system_id)
      cal_id = system.email
      head(:not_found) unless cal_id

      event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
      head(:not_found) unless event

      # ensure we have the host event details
      if client.client_id == :office365 && event.host != calendar_id
        event = get_hosts_event(event)
        event_id = event.id.not_nil! # ameba:disable Lint/UselessAssign
      end

      metadata = get_event_metadata(event, system_id)
      parent_meta = metadata && metadata.event_id != event.id
      render json: StaffApi::Event.augment(event.not_nil!, cal_id, system, metadata, parent_meta)
    end

    head :bad_request
  end

  # ameba:disable Metrics/CyclomaticComplexity
  def destroy
    event_id = route_params["id"]
    notify_guests = query_params["notify"]? != "false"
    placeos_client = get_placeos_client

    cal_id = if user_cal = query_params["calendar"]?
               found = get_user_calendars.reject { |cal| cal.id != user_cal }.first?
               head(:not_found) unless found
               user_cal
             elsif system_id = query_params["system_id"]?
               system = placeos_client.systems.fetch(system_id)
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
      head(:forbidden) if !(system && !check_access(user.roles, [system.id] + system.zones).none?)
    end

    # ensure we have the host event details
    if client.client_id == :office365 && event.host != cal_id
      event = get_hosts_event(event)
      event_id = event.id.not_nil!
    end

    client.delete_event(user_id: host, id: event_id, calendar_id: host, notify: notify_guests)

    if system
      EventMetadata.query.by_tenant(tenant.id).where({event_id: event_id}).delete_all

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

  #
  # Event Guest management
  #
  get("/:id/guests", :guest_list) do
    event_id = route_params["id"]
    render(json: [] of Nil) if query_params["calendar"]?
    system_id = query_params["system_id"]?
    render :bad_request, json: {error: "missing system_id param"} unless system_id

    cal_id = get_placeos_client.systems.fetch(system_id).email
    render(json: [] of Nil) unless cal_id

    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    head(:not_found) unless event

    # ensure we have the host event details
    if client.client_id == :office365 && event.host != cal_id
      event = get_hosts_event(event)
      event_id = event.id # ameba:disable Lint/UselessAssign
    end

    # Grab meeting metadata if it exists
    metadata = get_event_metadata(event, system_id)
    parent_meta = metadata && metadata.event_id != event.id
    render(json: [] of Nil) unless metadata

    # Find anyone who is attending
    visitors = metadata.attendees.to_a
    render(json: [] of Nil) if visitors.empty?

    # Grab the guest profiles if they exist
    guests = visitors.each_with_object({} of String => Guest) { |visitor, obj| obj[visitor.guest.email.not_nil!] = visitor.guest }

    # Merge the visitor data with guest profiles
    visitors = visitors.map { |visitor| attending_guest(visitor, guests[visitor.guest.email]?, parent_meta) }

    render json: visitors
  end

  post("/:id/guests/:guest_id/checkin", :guest_checkin) do
    checkin = (query_params["state"]? || "true") == "true"
    event_id = route_params["id"]
    guest_email = route_params["guest_id"].downcase
    host_mailbox = query_params["host_mailbox"]?.try &.downcase

    if user_token.scope.includes?("guest")
      guest_event_id, system_id = user.roles
      guest_token_email = user.email.downcase

      head :forbidden unless event_id == guest_event_id && guest_email == guest_token_email
    else
      system_id = query_params["system_id"]?
      render :bad_request, json: {error: "missing system_id param"} unless system_id
    end

    guest = if guest_email.includes?('@')
              Guest.query.by_tenant(tenant.id).find!({email: guest_email})
            else
              Guest.query.by_tenant(tenant.id).find!(guest_email.to_i64)
            end

    sys_email = get_placeos_client.systems.fetch(system_id).email
    render :not_found, json: {error: "system #{system_id} missing resource email"} unless sys_email

    # The provided event id defaults to the system ID however for office365
    # we may need to explicitly provide the hosts mailbox if the rooms event id is unknown
    cal_id = host_mailbox || sys_email

    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    render :not_found, json: {error: "event #{event_id} not found in #{cal_id}"} if event.nil?

    # ensure we have the host event details
    if client.client_id == :office365 && event.host != cal_id
      event = get_hosts_event(event)
      event_id = event.id.not_nil!
    end

    eventmeta = get_migrated_metadata(event, system_id)
    render :not_found, json: {error: "metadata for event #{event_id} not found, no visitors expected"} unless eventmeta

    if attendee = Attendee.query.by_tenant(tenant.id).find({guest_id: guest.id, event_id: eventmeta.not_nil!.id})
      attendee.update!({checked_in: checkin})

      guest_details = attendee.guest

      # Check the event is still on
      host_email = eventmeta.not_nil!.host_email
      event = client.get_event(host_email, id: event_id)
      render :not_found, json: {error: "the event #{event_id} in the hosts calendar #{host_email} is cancelled"} unless event && event.status != "cancelled"

      # Update PlaceOS with an signal "staff/guest/checkin"
      spawn do
        get_placeos_client.root.signal("staff/guest/checkin", {
          action:         :checkin,
          checkin:        checkin,
          system_id:      system_id,
          event_id:       event_id,
          host:           host_email,
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
      render :not_found, json: {error: "the attendee #{guest.email} was not found to be attending this event"}
    end
  end

  private def update_status(status)
    event_id = route_params["id"]
    system_id = query_params["system_id"]

    # Check this system has an associated resource
    system = get_placeos_client.systems.fetch(system_id)
    cal_id = system.email
    head(:not_found) unless cal_id

    # Check the event was in the calendar
    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    head(:not_found) unless event

    # User details
    user_email = user.email
    host = event.host || user_email

    # check permisions
    existing_attendees = event.attendees.try(&.map { |a| a.email }) || [] of String
    unless user_email == host || user_email.in?(existing_attendees) || host.in?(existing_attendees)
      # may be able to delete on behalf of the user
      head(:forbidden) if !(system && !check_access(user.roles, [system.id] + system.zones).none?)
    end

    # ensure we have the host event details
    if client.client_id == :office365 && event.host != cal_id
      event = get_hosts_event(event)
      event_id = event.id # ameba:disable Lint/UselessAssign
    end

    # Existing attendees without system
    attendees = event.attendees.uniq.reject { |attendee| attendee.email.downcase == cal_id.downcase }
    # Adding back system with correct status
    attendees << PlaceCalendar::Event::Attendee.new(name: cal_id, email: cal_id, response_status: status)

    event.not_nil!.attendees = attendees

    # Update the event (user must be a resource approver)
    updated_event = client.update_event(user_id: user.email, event: event, calendar_id: cal_id)

    # Return the full event details
    metadata = get_event_metadata(event, system_id)

    render json: StaffApi::Event.augment(updated_event.not_nil!, system.email, system, metadata)
  end
end
