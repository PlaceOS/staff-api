class Events < Application
  base "/api/staff/v1/events"

  # Skip scope check for relevant routes
  skip_action :check_jwt_scope, only: [:show, :patch_metadata, :guest_checkin]

  # lists events occuring in the period provided, by default on the current users calendar
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "period_start", description: "event period start as a unix epoch", example: "1661725146")]
    starting : Int64,
    @[AC::Param::Info(name: "period_end", description: "event period end as a unix epoch", example: "1661743123")]
    ending : Int64,
    @[AC::Param::Info(description: "a comma seperated list of calendar ids, recommend using `system_id` for resource calendars", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil,
    @[AC::Param::Info(description: "a comma seperated list of zone ids", example: "zone-123,zone-456")]
    zone_ids : String? = nil,
    @[AC::Param::Info(description: "a comma seperated list of event spaces", example: "sys-1234,sys-5678")]
    system_ids : String? = nil,
    @[AC::Param::Info(description: "includes events that have been marked as cancelled", example: "true")]
    include_cancelled : Bool = false
  ) : Array(PlaceCalendar::Event)
    period_start = Time.unix(starting)
    period_end = Time.unix(ending)

    calendars = matching_calendar_ids(calendars, zone_ids, system_ids, allow_default: true)

    Log.context.set(calendar_size: calendars.size.to_s)
    return [] of PlaceCalendar::Event unless calendars.size > 0

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
      Log.debug { "requesting events from: #{request.path}" }
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
    # Set size hint to save reallocation of Array
    metadata_ids = Array(String).new(initial_capacity: results.size)
    ical_uids = Array(String).new(initial_capacity: results.size)

    results.each do |(_calendar_id, system, event)|
      # NOTE:: we should be able to swtch to using the ical uids only in the future
      # 01/06/2022 MS does not return unique ical uids for recurring bookings: https://devblogs.microsoft.com/microsoft365dev/microsoft-graph-calendar-events-icaluid-update/
      # However they have a new `uid` field on the beta API which we can use when it's moved to production

      # Attempt to return metadata regardless of system id availability
      metadata_ids << event.id.not_nil!
      ical_uids << event.ical_uid.not_nil!

      # TODO: Handle recurring O365 events with differing `ical_uid`
      # Determine how to deal with recurring events in Office365 where the `ical_uid` is  different for each recurrance
      metadata_ids << event.recurring_event_id.not_nil! if event.recurring_event_id && event.recurring_event_id != event.id
    end

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

  protected def can_create?(user_email : String, host_email : String, attendees : Array(String)) : Bool
    # if the current user is not then host then they should be an attendee
    return true if user_email == host_email
    service_account = tenant.service_account.try(&.downcase)
    if host_email == service_account
      return attendees.includes?(user_email)
    end
    !!get_user_calendars.find { |cal| cal.id.try(&.downcase) == host_email }
  end

  # creates a new calendar event
  @[AC::Route::POST("/", body: :input_event, status_code: HTTP::Status::CREATED)]
  def create(input_event : PlaceCalendar::Event) : PlaceCalendar::Event
    placeos_client = get_placeos_client

    # get_user_calendars returns only calendars where the user has write access
    user_email = user.email.downcase
    host = input_event.host.try(&.downcase) || user_email
    attendee_emails = input_event.attendees.map { |attend| attend.email.downcase }
    raise Error::Forbidden.new("user #{user_email} does not have write access to #{host} calendar") unless can_create?(user_email, host, attendee_emails)

    system_id = input_event.system_id || input_event.system.try(&.id)
    if system_id
      system = placeos_client.systems.fetch(system_id)
      system_email = system.email.presence.not_nil!
      system_attendee = PlaceCalendar::Event::Attendee.new(name: system.display_name.presence || system.name, email: system_email, resource: true)
      input_event.attendees << system_attendee
    end

    # Ensure the host is configured to be attending the meeting and has accepted the meeting
    attendees = input_event.attendees.uniq.reject { |attendee| attendee.email.downcase == host }
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
          event:     created_event,
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

            guest = if existing_guest = Guest.query.by_tenant(tenant.id).find({email: email})
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
              guest.extension_data = attendee_ext_data
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
                event_summary:  created_event.title,
                event_starting: created_event.event_start.not_nil!.to_unix,
                attendee_name:  attendee.name,
                attendee_email: attendee.email,
                zones:          sys.zones,
              })
            end
          end
        end

        return StaffApi::Event.augment(created_event, sys.email, sys, meta)
      end

      Log.info { "no extension data for event #{created_event.id} in #{sys.id}, #{ext_data}" }
      return StaffApi::Event.augment(created_event, sys.email, sys)
    end

    Log.info { "no system provided for event #{created_event.id}" }
    StaffApi::Event.augment(created_event, host)
  end

  # patches an existing booking with the changes provided
  # by default it assumes the event exists on the users calendar.
  # you can provide a calendar param to override this default
  # or you can provide a system id if the event exists on a resource calendar
  #
  # Note: event metadata is associated with a resource calendar, not the hosts event.
  # so if you want to update an event and the metadata then you need to provide both
  # the `calendar` param and the `system_id` param
  @[AC::Route::PATCH("/:id", body: :changes)]
  @[AC::Route::PUT("/:id", body: :changes)]
  def update(
    changes : PlaceCalendar::Event,
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    original_id : String,
    @[AC::Param::Info(name: "system_id", description: "the event space associated with this event", example: "sys-1234")]
    associated_system : String? = nil,
    @[AC::Param::Info(name: "calendar", description: "the calendar associated with this event id", example: "user@org.com")]
    user_cal : String? = nil
  ) : PlaceCalendar::Event
    event_id = original_id
    system_id = (associated_system || changes.system_id).presence

    placeos_client = get_placeos_client

    if user_cal
      cal_id = user_cal.downcase
      found = get_user_calendars.reject { |cal| cal.id != cal_id }.first?
      raise AC::Route::Param::ValueError.new("user doesn't have write access to #{cal_id}", "calendar") unless found
    end

    if system_id
      system = placeos_client.systems.fetch(system_id)
      if cal_id.nil?
        sys_cal = cal_id = system.email.presence
        raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless sys_cal
      end
    end

    # defaults to the current users email
    cal_id = user.email unless cal_id

    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("failed to find event #{event_id} searching on #{cal_id} as #{user.email}") unless event

    # ensure we have the host event details
    if client.client_id == :office365 && event.host != cal_id
      event = get_hosts_event(event)
      event_id = event.id.not_nil!
      changes.id = event_id
    end

    # User details
    user_email = user.email.downcase
    host = event.host.try(&.downcase) || user_email

    # check permisions
    existing_attendees = event.attendees.try(&.map { |a| a.email.downcase }) || [] of String
    unless user_email == host || user_email.in?(existing_attendees)
      # may be able to edit on behalf of the user
      raise Error::Forbidden.new("user #{user_email} not involved in meeting and no role is permitted to make this change") if !(system && !check_access(user.roles, [system.id] + system.zones).none?)
    end

    # Check if attendees need updating
    update_attendees = !changes.attendees.nil?
    attendees = changes.attendees.try(&.map { |a| a.email.downcase }) || existing_attendees

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
      raise AC::Route::Param::ValueError.new("attempting to move location and system '#{new_system.name}' (#{new_system_id}) does not have a resource email address specified", "event.system_id") unless new_sys_cal

      # Check this room isn't already invited
      raise AC::Route::Param::ValueError.new("attempting to move location and system '#{new_system.name}' (#{new_system_id}) is already marked as a resource", "event.system_id") if existing_attendees.includes?(new_sys_cal)

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
      meta = get_migrated_metadata(event, system_id.not_nil!, system.email.not_nil!) || EventMetadata.new

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
        meta.ext_data = JSON::Any.new(data)
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

            guest = if existing_guest = Guest.query.by_tenant(tenant.id).find({email: email})
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
              guest.extension_data = attendee_ext_data
            end

            guest.save!

            # Create attendees
            attend = existing_lookup[email]? || Attendee.new

            previously_visiting = if attend.persisted?
                                    attend.visit_expected
                                  else
                                    attend.set({
                                      checked_in: false,
                                      tenant_id:  tenant.id,
                                    })
                                    false
                                  end

            attend.update!({
              event_id:       meta.id.not_nil!,
              guest_id:       guest.id,
              visit_expected: attendee.visit_expected.not_nil!,
            })

            next unless attend.visit_expected

            if !previously_visiting || changing_room
              spawn do
                sys = system.not_nil!

                placeos_client.root.signal("staff/guest/attending", {
                  action:         :meeting_update,
                  system_id:      sys.id,
                  event_id:       event_id,
                  host:           host,
                  resource:       sys.email,
                  event_summary:  updated_event.not_nil!.title,
                  event_starting: updated_event.not_nil!.event_start.not_nil!.to_unix,
                  attendee_name:  attendee.name,
                  attendee_email: attendee.email,
                  zones:          sys.zones,
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
                event_summary:  updated_event.not_nil!.title,
                event_starting: updated_event.not_nil!.event_start.not_nil!.to_unix,
                attendee_name:  guest.name,
                attendee_email: guest.email,
                zones:          sys.zones,
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
          event_id:  original_id,
          host:      host,
          resource:  sys.email,
          event:     updated_event,
          ext_data:  eventmeta.try &.ext_data,
        })
      end

      StaffApi::Event.augment(updated_event.not_nil!, system.not_nil!.email, system, eventmeta)
    else
      # see if there are any relevent systems associated with the event
      resource_calendars = (updated_event.attendees || StaffApi::Event::NOP_PLACE_CALENDAR_ATTENDEES).compact_map do |attend|
        attend.email if attend.resource
      end

      if !resource_calendars.empty?
        systems = placeos_client.systems.with_emails(resource_calendars)
        if sys = systems.first?
          meta = get_migrated_metadata(updated_event, sys.id.not_nil!, sys.email.not_nil!)
          return StaffApi::Event.augment(updated_event.not_nil!, host, sys, meta)
        end
      end

      StaffApi::Event.augment(updated_event.not_nil!, host)
    end
  end

  # Patches the metadata on a booking without touching the calendar event
  # only updates the keys provided in the request
  #
  # by default it assumes the event exists on the resource calendar.
  # you can provide a calendar param to override this default
  @[AC::Route::PATCH("/:id/metadata/:system_id", body: :changes)]
  def patch_metadata(
    changes : JSON::Any,
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    original_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String,
    @[AC::Param::Info(name: "calendar", description: "the calendar associated with this event id", example: "user@org.com")]
    user_cal : String? = nil
  ) : JSON::Any
    update_metadata(changes.as_h, original_id, system_id, user_cal, merge: true)
  end

  # Replaces the metadata on a booking without touching the calendar event
  # by default it assumes the event exists on the resource calendar.
  # you can provide a calendar param to override this default
  @[AC::Route::PUT("/:id/metadata/:system_id", body: :changes)]
  def replace_metadata(
    changes : JSON::Any,
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    original_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String,
    @[AC::Param::Info(name: "calendar", description: "the calendar associated with this event id", example: "user@org.com")]
    user_cal : String? = nil
  ) : JSON::Any
    update_metadata(changes.as_h, original_id, system_id, user_cal, merge: false)
  end

  protected def update_metadata(changes : Hash(String, JSON::Any), original_id : String, system_id : String, event_calendar : String?, merge : Bool = false)
    event_id = original_id
    placeos_client = get_placeos_client

    # Guest access
    if user_token.guest_scope?
      guest_event_id, guest_system_id = user.roles
      system_id ||= guest_system_id
      raise Error::Forbidden.new("guest #{user_token.id} attempting to view a system they are not associated with") unless system_id == guest_system_id
    end

    system = placeos_client.systems.fetch(system_id)
    cal_id = system.email.presence
    raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless cal_id

    user_email = user_token.guest_scope? ? cal_id : user.email.downcase
    cal_id = event_calendar || cal_id
    event = client.get_event(user_email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

    # ensure we have the host event details
    # TODO:: instead of this we should store ical UID in the guest JWT
    if client.client_id == :office365 && event.host != user_email
      begin
        event = get_hosts_event(event)
        event_id = event.id.not_nil!
      rescue PlaceCalendar::Exception
        # we might not have access
      end
    end

    # Guests can update extension_data to indicate their order
    if user_token.guest_scope?
      raise Error::Forbidden.new("guest #{user_token.id} attempting to edit an event they are not associated with") unless merge && guest_event_id.in?({original_id, event_id, event.recurring_event_id}) && system_id == guest_system_id
    else
      attendees = event.attendees.try(&.map { |a| a.email }) || [] of String
      raise Error::Forbidden.new("user #{user_email} not involved in meeting and no role is permitted to make this change") unless is_support? || user_email == event.host || user_email.in?(attendees)
    end

    # attempt to find the metadata
    meta = get_migrated_metadata(event, system_id.not_nil!, cal_id) || EventMetadata.new
    meta.system_id = system.id.not_nil!
    meta.event_id = event.id.not_nil!
    meta.ical_uid = event.ical_uid.not_nil!
    meta.recurring_master_id = event.recurring_event_id || event.id if event.recurring
    meta.event_start = event.event_start.not_nil!.to_unix
    meta.event_end = event.event_end.not_nil!.to_unix
    meta.resource_calendar = system.email.not_nil!
    meta.host_email = event.host.not_nil!
    meta.tenant_id = tenant.id

    # Updating extension data by merging into existing.
    if merge && meta.ext_data_column.defined? && (meta_ext_data = meta.ext_data)
      data = meta_ext_data.as_h
      changes.each { |key, value| data[key] = value }
    else
      data = changes
    end

    # Needed for clear to assign the updated json correctly
    meta.ext_data_column.clear
    meta.ext_data = JSON::Any.new(data)
    meta.save!

    spawn do
      placeos_client.root.signal("staff/event/changed", {
        action:    :update,
        system_id: system.id,
        event_id:  original_id,
        host:      event.host,
        resource:  system.email,
        event:     event,
        ext_data:  meta.ext_data,
      })
    end

    meta.ext_data.not_nil!
  end

  # returns the event requested.
  # by default it assumes the event exists on the users calendar.
  # you can provide a calendar param to override this default
  # or you can provide a system id if the event exists on a resource calendar
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    original_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String? = nil,
    @[AC::Param::Info(name: "calendar", description: "the users calendar associated with this event", example: "user@org.com")]
    user_cal : String? = nil
  ) : PlaceCalendar::Event
    placeos_client = get_placeos_client
    event_id = original_id

    # Guest access
    if user_token.guest_scope?
      guest_event_id, guest_system_id = user.roles
      system_id ||= guest_system_id
      raise Error::Forbidden.new("guest #{user_token.id} attempting to view an event they are not associated with") unless system_id == guest_system_id
    end

    if system_id
      # Need to grab the calendar associated with this system
      system = placeos_client.systems.fetch(system_id)
      cal_id = system.email
      user_email = user_token.guest_scope? ? cal_id : user.email
      raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless cal_id

      event = client.get_event(user_email.not_nil!, id: event_id, calendar_id: cal_id)
      raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

      # ensure we have the host event details
      # TODO:: instead of this we should store ical UID in the guest JWT
      if client.client_id == :office365 && event.host != cal_id
        begin
          event = get_hosts_event(event)
          event_id = event.id.not_nil!
        rescue PlaceCalendar::Exception
          # we might not have access
        end
      end

      if user_token.guest_scope?
        raise Error::Forbidden.new("guest #{user_token.id} attempting to view an event they are not associated with") unless guest_event_id.in?({original_id, event_id, event.recurring_event_id}) && system_id == guest_system_id
      end

      metadata = get_event_metadata(event, system_id)
      parent_meta = !metadata.try &.for_event_instance?(event, client.client_id)
      StaffApi::Event.augment(event.not_nil!, cal_id, system, metadata, parent_meta)
    else
      # Need to confirm the user can access this calendar
      if user_cal
        user_cal = user_cal.downcase
        found = get_user_calendars.reject { |cal| cal.id.try(&.downcase) != user_cal }.first?
      else
        user_cal = user.email
        found = true
      end
      raise Error::Forbidden.new("user #{user.email} is not permitted to view calendar #{user_cal}") unless found

      # Grab the event details
      event = client.get_event(user.email, id: event_id, calendar_id: user_cal)
      raise Error::NotFound.new("event #{event_id} not found on calendar #{user_cal}") unless event

      # see if there are any relevent metadata details
      ev_ical_uid = event.ical_uid
      metadata = EventMetadata.query.by_tenant(tenant.id).where { ical_uid.in?([ev_ical_uid]) }.to_a.first?

      # see if there are any relevent systems associated with the event
      resource_calendars = (event.attendees || StaffApi::Event::NOP_PLACE_CALENDAR_ATTENDEES).compact_map do |attend|
        attend.email if attend.resource
      end

      if !resource_calendars.empty?
        systems = placeos_client.systems.with_emails(resource_calendars)
        if system = systems.first?
          return StaffApi::Event.augment(event.not_nil!, user_cal, system, metadata)
        end
      end

      StaffApi::Event.augment(event.not_nil!, user_cal, metadata: metadata)
    end
  end

  # deletes the event from the calendar, it will not appear as cancelled, it will be gone
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String? = nil,
    @[AC::Param::Info(name: "calendar", description: "the users calendar associated with this event", example: "user@org.com")]
    user_cal : String? = nil,
    @[AC::Param::Info(name: "notify", description: "set to `false` to prevent attendees being notified of the change", example: "false")]
    notify_guests : Bool = true
  ) : Nil
    cancel_event(event_id, notify_guests, system_id, user_cal, delete: true)
  end

  # cancels the meeting without deleting it
  # visually the event will remain on the calendar with a line through it
  # NOTE:: any body data you post will be used as the message body in the declined message
  @[AC::Route::POST("/:id/decline", status_code: HTTP::Status::ACCEPTED)]
  def decline(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String? = nil,
    @[AC::Param::Info(name: "calendar", description: "the users calendar associated with this event", example: "user@org.com")]
    user_cal : String? = nil,
    @[AC::Param::Info(name: "notify", description: "set to `false` to prevent attendees being notified of the change", example: "false")]
    notify_guests : Bool = true
  ) : Nil
    cancel_event(event_id, notify_guests, system_id, user_cal, delete: false)
  end

  protected def cancel_event(event_id : String, notify_guests : Bool, system_id : String?, user_cal : String?, delete : Bool)
    placeos_client = get_placeos_client

    if user_cal
      cal_id = user_cal.downcase
      found = get_user_calendars.reject { |cal| cal.id != cal_id }.first?
      raise AC::Route::Param::ValueError.new("user doesn't have write access to #{cal_id}", "calendar") unless found
    end

    if system_id
      system = placeos_client.systems.fetch(system_id)
      if cal_id.nil?
        sys_cal = cal_id = system.email.presence
        raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless sys_cal
      end
    end

    # defaults to the current users email
    cal_id = user.email unless cal_id

    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("failed to find event #{event_id} searching on #{cal_id} as #{user.email}") unless event

    # User details
    user_email = tenant.service_account.try(&.downcase) || user.email.downcase
    host = event.host.try(&.downcase) || user_email

    # check permisions
    existing_attendees = event.attendees.try(&.map { |a| a.email.downcase }) || [] of String
    unless user_email == host || user_email.in?(existing_attendees)
      # may be able to delete on behalf of the user
      raise Error::Forbidden.new("user #{user_email} not involved in meeting and no role is permitted to make this change") if !(system && !check_access(user.roles, [system.id] + system.zones).none?)
    end

    # we don't need host details for delete / decline as we want it to occur on the calendar specified
    # unless using a service account and then we can only use the host calendar
    if client.client_id == :office365 && event.host != cal_id && (srv_acct = tenant.service_account)
      event = get_hosts_event(event, tenant.service_account)
      event_id = event.id.not_nil!
      cal_id = srv_acct
    end

    if delete
      client.delete_event(user_id: cal_id, id: event_id, calendar_id: cal_id, notify: notify_guests)
    else
      comment = request.body.try &.gets_to_end.presence
      client.decline_event(
        user_id: cal_id,
        id: event_id,
        calendar_id: cal_id,
        notify: notify_guests,
        comment: comment
      )
    end

    if system
      EventMetadata.query.by_tenant(tenant.id).where({event_id: event_id}).delete_all

      spawn do
        placeos_client.root.signal("staff/event/changed", {
          action:    :cancelled,
          system_id: system.not_nil!.id,
          event_id:  event_id,
          resource:  system.not_nil!.email,
          event:     event,
        })
      end
    end
  end

  # approves / accepts the meeting on behalf of the event space
  @[AC::Route::POST("/:id/approve")]
  def approve(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String
  ) : PlaceCalendar::Event
    update_status(event_id, system_id, "accepted")
  end

  # rejects / declines the meeting on behalf of the event space
  @[AC::Route::POST("/:id/reject")]
  def reject(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String
  ) : PlaceCalendar::Event
    update_status(event_id, system_id, "declined")
  end

  private def update_status(event_id : String, system_id : String, status : String)
    # Check this system has an associated resource
    system = get_placeos_client.systems.fetch(system_id)
    cal_id = system.email
    raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless cal_id

    # Check the event was in the calendar
    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

    # User details
    user_email = user.email.downcase
    host = event.host.try(&.downcase) || user_email

    # check permisions
    existing_attendees = event.attendees.try(&.map { |a| a.email.downcase }) || [] of String
    unless user_email == host || user_email.in?(existing_attendees)
      raise Error::Forbidden.new("user #{user_email} not involved in meeting and no role is permitted to make this change") if !(system && !check_access(user.roles, [system.id] + system.zones).none?)
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

    StaffApi::Event.augment(updated_event.not_nil!, system.email, system, metadata)
  end

  # Event Guest management
  @[AC::Route::GET("/:id/guests")]
  def guest_list(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String
  ) : Array(Guest::GuestResponse | Attendee::AttendeeResponse)
    cal_id = get_placeos_client.systems.fetch(system_id).email
    return [] of Guest::GuestResponse | Attendee::AttendeeResponse unless cal_id

    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

    # Grab meeting metadata if it exists
    metadata = get_event_metadata(event, system_id)
    parent_meta = !metadata.try &.for_event_instance?(event, client.client_id)
    return [] of Guest::GuestResponse | Attendee::AttendeeResponse unless metadata

    # Find anyone who is attending
    visitors = metadata.attendees.to_a
    return [] of Guest::GuestResponse | Attendee::AttendeeResponse if visitors.empty?

    # Grab the guest profiles if they exist
    guests = visitors.each_with_object({} of String => Guest) { |visitor, obj| obj[visitor.guest.email.not_nil!] = visitor.guest }

    # Merge the visitor data with guest profiles
    visitors.map { |visitor| attending_guest(visitor, guests[visitor.guest.email]?, parent_meta) }
  end

  # example route: /extension_metadata?field_name=colour&value=blue
  @[AC::Route::GET("/extension_metadata")]
  def extension_metadata(
    @[AC::Param::Info(description: "the field we want to query", example: "status")]
    field_name : String,
    @[AC::Param::Info(description: "value we want to match", example: "approved")]
    value : String
  ) : Array(EventMetadata::Assigner)
    EventMetadata.by_ext_data(field_name, value).to_a.map do |metadata|
      EventMetadata::Assigner.from_json(metadata.to_json)
    end
  end

  # a guest has arrived for a meeting in person.
  # This route can be used to notify hosts
  @[AC::Route::POST("/:id/guests/:guest_id/check_in")]
  @[AC::Route::POST("/:id/guests/:guest_id/checkin")]
  def guest_checkin(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    original_id : String,
    @[AC::Param::Info(name: "guest_id", description: "the email of the guest we want to checkin", example: "person@external.com")]
    guest_email : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String? = nil,
    @[AC::Param::Info(name: "state", description: "the checkin state, defaults to `true`", example: "false")]
    checkin : Bool = true
  ) : Guest::GuestResponse
    guest_id = guest_email.downcase
    event_id = original_id

    if user_token.guest_scope?
      guest_event_id, guest_system_id = user.roles
      system_id ||= guest_system_id
      guest_token_email = user.email.downcase
      raise Error::Forbidden.new("guest #{user_token.id} attempting to check into an event they are not associated with") unless system_id == guest_system_id
    else
      raise AC::Route::Param::ValueError.new("system_id param is required except for guest scope", "system_id") unless system_id
    end

    guest_email = if guest_id.includes?('@')
                    guest_id.strip.downcase
                  else
                    Guest.query.by_tenant(tenant.id).find!(guest_id.to_i64).email
                  end

    raise Error::Forbidden.new("guest #{user_token.id} attempting to check into an event as #{guest_email}") if user_token.guest_scope? && guest_email != guest_token_email

    system = get_placeos_client.systems.fetch(system_id)
    cal_id = system.email
    raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless cal_id

    user_email = user_token.guest_scope? ? cal_id : user.email.downcase
    event = client.get_event(user_email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

    # Check the guest email is in the event
    attendee = event.attendees.find { |attending| attending.email.downcase == guest_email }
    raise Error::NotFound.new("guest #{guest_email} is not an attendee on the event") unless attendee

    # Create the guest model if not already in the database
    guest = begin
      Guest.query.by_tenant(tenant.id).find!({email: guest_email})
    rescue Clear::SQL::RecordNotFoundError
      g = Guest.new({
        tenant_id:      tenant.id,
        email:          guest_email,
        name:           attendee.name,
        banned:         false,
        dangerous:      false,
        extension_data: JSON::Any.new({} of String => JSON::Any),
      })
      raise Error::ModelValidation.new(g.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating guest data") if !g.save
      g
    end

    if user_token.guest_scope?
      raise Error::Forbidden.new("guest #{user_token.id} attempting to view an event they are not associated with") unless guest_event_id.in?({original_id, event_id, event.recurring_event_id})
    end

    eventmeta = get_migrated_metadata(event, system_id, cal_id) || EventMetadata.create!({
      system_id:           system.id.not_nil!,
      event_id:            event.id.not_nil!,
      recurring_master_id: (event.recurring_event_id || event.id if event.recurring),
      event_start:         event.event_start.not_nil!.to_unix,
      event_end:           event.event_end.not_nil!.to_unix,
      resource_calendar:   cal_id,
      host_email:          event.host.not_nil!,
      tenant_id:           tenant.id,
      ical_uid:            event.ical_uid.not_nil!,
    })

    if attendee = Attendee.query.by_tenant(tenant.id).find({guest_id: guest.id, event_id: eventmeta.not_nil!.id})
      attendee.update!({checked_in: checkin})
    else
      attendee = Attendee.create!({
        event_id:       eventmeta.id.not_nil!,
        guest_id:       guest.id,
        visit_expected: true,
        checked_in:     checkin,
        tenant_id:      tenant.id,
      })
    end

    # Check the event is still on
    raise Error::NotFound.new("the event #{event_id} in the hosts calendar #{event.host} is cancelled") unless event && event.status != "cancelled"

    # Update PlaceOS with an signal "staff/guest/checkin"
    spawn do
      get_placeos_client.root.signal("staff/guest/checkin", {
        action:         :checkin,
        id:             guest.id,
        checkin:        checkin,
        system_id:      system_id,
        event_id:       event_id,
        host:           event.host,
        resource:       eventmeta.resource_calendar,
        event_summary:  event.not_nil!.title,
        event_starting: eventmeta.event_start,
        attendee_name:  guest.name,
        attendee_email: guest.email,
        zones:          system.zones,
      })
    end

    attending_guest(attendee, attendee.guest, false, event).as(Guest::GuestResponse)
  end
end
