class Events < Application
  base "/api/staff/v1/events"

  # Skip scope check for relevant routes
  skip_action :check_jwt_scope, only: [:show, :patch_metadata, :guest_checkin]

  @[AC::Route::Filter(:before_action, only: [:notify_change])]
  private def protected_route
    raise Error::Forbidden.new unless is_support?
  end

  @[AC::Route::Filter(:before_action, only: [:extension_metadata])]
  private def confirm_access(
    system_id : String? = nil
  )
    return if is_support?

    if system_id
      system = PlaceOS::Model::ControlSystem.find!(system_id)
      return if check_access(current_user.groups, system.zones || [] of String).can_manage?
    end

    raise Error::Forbidden.new("user not in an appropriate user group or involved in the meeting")
  end

  # update includes a bunch of moving parts so we want to roll back if something fails
  @[AC::Route::Filter(:around_action, only: [:update])]
  def wrap_in_transaction(&)
    PgORM::Database.transaction do
      yield
    end
  end

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
    include_cancelled : Bool = false,
    @[AC::Param::Info(name: "ical_uid", description: "the ical uid of the event you are looking for", example: "sqvitruh3ho3mrq896tplad4v8")]
    icaluid : String? = nil
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
        showDeleted: include_cancelled,
        ical_uid: icaluid
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

    # find any missing system ids (event_id => calendar_id)
    event_resources = {} of String => String

    results.each do |(_calendar_id, system, event)|
      # NOTE:: we should be able to swtch to using the ical uids only in the future
      # 01/06/2022 MS does not return unique ical uids for recurring bookings: https://devblogs.microsoft.com/microsoft365dev/microsoft-graph-calendar-events-icaluid-update/
      # However they have a new `uid` field on the beta API which we can use when it's moved to production

      raise Error::BadUpstreamResponse.new("id must be present on event") unless event_id = event.id
      raise Error::BadUpstreamResponse.new("ical_uid must be present on event") unless event_ical_uid = event.ical_uid

      # Attempt to return metadata regardless of system id availability
      metadata_ids << event_id
      ical_uids << event_ical_uid

      # TODO: Handle recurring O365 events with differing `ical_uid`
      # Determine how to deal with recurring events in Office365 where the `ical_uid` is  different for each recurrance
      if (recurring_event_id = event.recurring_event_id) && recurring_event_id != event.id
        metadata_ids << recurring_event_id
      end

      # check if there is possible system information available
      if system.nil? && (attendee = event.attendees.find(&.resource))
        event_resources[event.id.as(String)] = attendee.email.downcase
      end
    end

    metadata_ids.uniq!

    # Don't perform the query if there are no calendar entries
    if !metadata_ids.empty?
      EventMetadata.by_tenant(tenant.id).where(event_id: metadata_ids).each { |meta|
        metadatas[meta.event_id] = meta
      }
    end

    # Metadata is stored against a resource calendar which in office365 can only
    # be matched by the `ical_uid`
    if (client.client_id == :office365) && ical_uids.uniq! && !ical_uids.empty?
      EventMetadata.by_tenant(tenant.id).where(ical_uid: ical_uids).each { |meta|
        metadatas[meta.ical_uid] = meta
      }
    end

    # grab the system details for resource calendars, if they exist
    system_emails = {} of String => PlaceOS::Client::API::Models::System
    if !event_resources.empty?
      systems = get_placeos_client.systems.with_emails event_resources.values.uniq!
      systems.each { |sys| system_emails[sys.email.as(String).downcase] = sys }
    end

    # return array of standardised events
    render json: results.compact_map { |(calendar_id, system, event)|
      next if icaluid && event.ical_uid != icaluid

      parent_meta = false
      metadata = metadatas[event.id]?
      if metadata.nil? && event.recurring_event_id
        metadata = metadatas[event.recurring_event_id]?
        parent_meta = true if metadata
      end

      if system.nil?
        if cal_id = event_resources[event.id.as(String)]?
          system = system_emails[cal_id]?
        end
      end

      # Workaround for Office365 where ical_uid is unique for each occurance and event_id is different in each calendar
      metadata = metadata || metadatas[event.ical_uid]? if client.client_id == :office365
      StaffApi::Event.augment(event, calendar_id, system, metadata, parent_meta)
    }
  end

  protected def can_create?(user_email : String, host_email : String, attendees : Array(String)) : Bool
    # if the current user is not then host then they should be an attendee
    return true if user_email == host_email
    return true if tenant.delegated

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
      raise Error::BadUpstreamResponse.new("email.presence must be present on system #{system_id}") unless system_email_presence = system.email.presence
      system_email = system_email_presence
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
    zone = if input_event.timezone.presence && (input_event_timezone = input_event.timezone)
             Time::Location.load(input_event_timezone)
           else
             get_timezone
           end

    raise Error::BadRequest.new("event_start must be present on input_event") unless input_event_start = input_event.event_start
    raise Error::BadRequest.new("event_end must be present on input_event") unless input_event_end = input_event.event_end
    input_event.event_start = input_event_start.in(zone)
    input_event.event_end = input_event_end.in(zone)

    created_event = client.create_event(user_id: host, event: input_event, calendar_id: host)
    raise Error::BadUpstreamResponse.new("event was not created") unless created_event

    # Update PlaceOS with an signal "/staff/event/changed"
    if sys = system
      # Grab the list of externals that might be attending
      attending = input_event.attendees.try(&.select { |attendee|
        attendee.visit_expected
      })

      # Save custom data
      meta = EventMetadata.new
      meta.ext_data = input_event.extension_data
      notify_created_or_updated(:create, sys, created_event, meta, can_skip: false)

      if attending && !attending.empty?
        # Create guests
        attending.each do |attendee|
          email = attendee.email.strip.downcase

          guest = if existing_guest = Guest.by_tenant(tenant.id).find_by?(email: email)
                    existing_guest.name = attendee.name if attendee.name.presence && existing_guest.name != attendee.name
                    existing_guest.phone = attendee.phone if attendee.phone.presence && existing_guest.phone != attendee.phone
                    existing_guest.organisation = attendee.organisation if attendee.organisation.presence && existing_guest.organisation != attendee.organisation
                    existing_guest
                  else
                    Guest.new(
                      email: email,
                      name: attendee.name,
                      preferred_name: attendee.preferred_name,
                      phone: attendee.phone,
                      organisation: attendee.organisation,
                      photo: attendee.photo,
                      notes: attendee.notes,
                      banned: attendee.banned || false,
                      dangerous: attendee.dangerous || false,
                      tenant_id: tenant.id,
                    )
                  end

          if attendee_ext_data = attendee.extension_data
            guest.extension_data = attendee_ext_data
          end
          guest.save!

          raise Error::InconsistentState.new("metadata id must be present") unless meta_id = meta.id
          raise Error::BadUpstreamResponse.new("event_start must be present on created_event #{created_event.id}") unless created_event_start = created_event.event_start

          # Create attendees
          Attendee.create!(
            event_id: meta_id,
            guest_id: guest.id,
            visit_expected: true,
            checked_in: false,
            tenant_id: tenant.id,
          )

          spawn do
            placeos_client.root.signal("staff/guest/attending", {
              action:         :meeting_created,
              system_id:      sys.id,
              event_id:       created_event.id,
              event_ical_uid: created_event.ical_uid,
              host:           host,
              resource:       sys.email,
              event_summary:  created_event.title,
              event_starting: created_event_start.to_unix,
              attendee_name:  attendee.name,
              attendee_email: attendee.email,
              zones:          sys.zones,
            })
          end
        end
      end

      return StaffApi::Event.augment(created_event, sys.email, sys, meta)
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
  #
  # when moving a room from one system to another, the `system_id` param should be
  # set to the current rooms associated system.
  # Then in the event body, the `system_id` field should be the new system.
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

    user_cal = user_cal.try &.downcase
    if user_cal == user.email
      cal_id = user_cal
    elsif user_cal
      cal_id = user_cal
      found = tenant.delegated || get_user_calendars.reject { |cal| cal.id.try(&.downcase) != cal_id }.first?
      raise AC::Route::Param::ValueError.new("user doesn't have write access to #{cal_id}", "calendar") unless found
    end

    if system_id
      system = placeos_client.systems.fetch(system_id)
      sys_cal = system.email.presence
      if cal_id.nil?
        cal_id = system.email.presence
        raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless sys_cal
      end
    end

    # defaults to the current users email
    cal_id = user.email unless cal_id

    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("failed to find event #{event_id} searching on #{cal_id} as #{user.email}") unless event

    # ensure we have the host event details
    if client.client_id == :office365 && event.host.try(&.downcase) != cal_id
      event = get_hosts_event(event)
      raise Error::BadUpstreamResponse.new("event id is missing") unless event_id = event.id
      changes.id = event_id
    end

    # User details
    user_email = user.email.downcase
    host = event.host.try(&.downcase) || user_email

    # check permisions
    existing_attendees = event.attendees.try(&.map { |a| a.email.downcase }) || [] of String
    if !tenant.delegated && user_email != host && !user_email.in?(existing_attendees)
      # may be able to edit on behalf of the user
      raise Error::Forbidden.new("user #{user_email} not involved in meeting and no role is permitted to make this change") if !(system && !check_access(user.roles, [system.id] + system.zones).forbidden?)
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
    changes.event_end = if event_end = changes.event_end
                          event_end.in(zone)
                        else
                          raise Error::BadRequest.new("event_end must be present")
                        end

    # are we moving the event room?
    changing_room = system_id != (changes.system_id.presence || system_id)
    if changing_room
      raise Error::BadRequest.new("system_id must be present when changing room") unless new_system_id = changes.system_id

      new_system = placeos_client.systems.fetch(new_system_id)
      new_sys_cal = new_system.email.presence.try &.downcase
      raise AC::Route::Param::ValueError.new("attempting to move location and system '#{new_system.name}' (#{new_system_id}) does not have a resource email address specified", "event.system_id") unless new_sys_cal

      # NOTE:: we're allowing this now, the expected behaviour is to overwrite the metadata
      # Check this room isn't already invited
      # raise AC::Route::Param::ValueError.new("attempting to move location and system '#{new_system.name}' (#{new_system_id}) is already marked as a resource", "event.system_id") if existing_attendees.includes?(new_sys_cal)

      # remove metadata from the existing room as new metadata will be used
      if existing_attendees.includes?(new_sys_cal) && (existing_meta = get_event_metadata(event, new_system_id))
        existing_meta.destroy
      end

      # Remove old and new room from attendees
      attendees_without_old_room = changes.attendees.uniq.reject do |attendee|
        attendee.email == new_sys_cal || (attendee.email == sys_cal && attendee.resource)
      end
      update_attendees = true
      remove_attendees = [] of String
      changes.attendees = attendees_without_old_room

      # Add the updated system as an attendee to the payload for update
      changes.attendees << PlaceCalendar::Event::Attendee.new(name: new_system.display_name.presence || new_system.name, email: new_sys_cal, resource: true)

      system = new_system
      system_id = system.id
    else
      # If room is not changing and it is not an attendee, add it.
      if system && !changes.attendees.map { |a| a.email }.includes?(sys_cal) && !sys_cal.nil?
        changes.attendees << PlaceCalendar::Event::Attendee.new(name: system.display_name.presence || system.name, email: sys_cal, resource: true)
      end
    end

    updated_event = client.update_event(user_id: host, event: changes, calendar_id: host)
    raise Error::BadUpstreamResponse.new("failed to update event #{event_id} as #{host}") unless updated_event

    if system
      raise Error::BadRequest.new("system_id must be present") if system_id.nil?
      raise Error::BadUpstreamResponse.new("email must be present on system #{system_id}") unless system_email = system.email

      meta = get_migrated_metadata(updated_event, system_id, system_email) || EventMetadata.new
      if extension_data = changes.extension_data
        meta_ext_data = meta.ext_data
        data = meta_ext_data ? meta_ext_data.as_h : Hash(String, JSON::Any).new
        # Updating extension data by merging into existing.
        extension_data.as_h.each { |key, value| data[key] = value }
        meta.ext_data = JSON::Any.new(data)
        meta.ext_data_will_change!
      end
      notify_created_or_updated(:update, system, updated_event, meta, can_skip: false)

      # Grab the list of externals that might be attending
      if update_attendees || changing_room
        existing_lookup = {} of String => Attendee
        existing = meta.attendees.to_a
        existing.each { |a| existing_lookup[a.email] = a }

        if !remove_attendees.empty?
          remove_attendees.each do |email|
            existing.select { |attend| (guest = attend.guest) && (guest.email == email) }.each do |attend|
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

            guest = if existing_guest = Guest.by_tenant(tenant.id).find_by?(email: email)
                      existing_guest
                    else
                      Guest.new(
                        email: email,
                        name: attendee.name,
                        preferred_name: attendee.preferred_name,
                        phone: attendee.phone,
                        organisation: attendee.organisation,
                        photo: attendee.photo,
                        notes: attendee.notes,
                        banned: attendee.banned || false,
                        dangerous: attendee.dangerous || false,
                        tenant_id: tenant.id,
                      )
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
                                    attend.assign_attributes(
                                      checked_in: false,
                                      tenant_id: tenant.id,
                                    )
                                    false
                                  end

            raise Error::InconsistentState.new("metadata id must be present") unless meta_id = meta.id
            raise Error::InconsistentState.new("visit_expected must be present") unless attendee_visit_expected = attendee.visit_expected

            attend.update!(
              event_id: meta_id,
              guest_id: guest.id,
              visit_expected: attendee_visit_expected,
            )

            next unless attend.visit_expected

            if !previously_visiting || changing_room
              spawn do
                sys = system
                raise Error::BadUpstreamResponse.new("event_start must be present on updated event #{updated_event.id}") unless updated_event_start = updated_event.event_start

                placeos_client.root.signal("staff/guest/attending", {
                  action:         :meeting_update,
                  system_id:      sys.id,
                  event_id:       event_id,
                  event_ical_uid: updated_event.ical_uid,
                  host:           host,
                  resource:       sys.email,
                  event_summary:  updated_event.title,
                  event_starting: updated_event_start.to_unix,
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
              sys = system
              raise Error::NotFound.new("guest not found for attendee #{attend.id}") unless guest = attend.guest
              raise Error::BadUpstreamResponse.new("event_start must be present on updated event #{updated_event.id}") unless updated_event_start = updated_event.event_start

              placeos_client.root.signal("staff/guest/attending", {
                action:         :meeting_update,
                system_id:      sys.id,
                event_id:       event_id,
                event_ical_uid: updated_event.ical_uid,
                host:           host,
                resource:       sys.email,
                event_summary:  updated_event.title,
                event_starting: updated_event_start.to_unix,
                attendee_name:  guest.name,
                attendee_email: guest.email,
                zones:          sys.zones,
              })
            end
          end
        end
      end

      StaffApi::Event.augment(updated_event, meta.resource_calendar, system, meta)
    else
      # see if there are any relevent systems associated with the event
      resource_calendars = (updated_event.attendees || StaffApi::Event::NOP_PLACE_CALENDAR_ATTENDEES).compact_map do |attend|
        attend.email if attend.resource
      end

      if !resource_calendars.empty?
        systems = placeos_client.systems.with_emails(resource_calendars)
        if sys = systems.first?
          raise Error::BadUpstreamResponse.new("id must be present on system") unless sys_id = sys.id
          raise Error::BadUpstreamResponse.new("email must be present on system #{sys_id}") unless sys_email = sys.email

          meta = get_migrated_metadata(updated_event, sys_id, sys_email)
          return StaffApi::Event.augment(updated_event, host, sys, meta)
        end
      end

      StaffApi::Event.augment(updated_event, host)
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
    user_cal : String? = nil,
    @[AC::Param::Info(description: "an alternative lookup for finding event-metadata", example: "5FC53010-1267-4F8E-BC28-1D7AE55A7C99")]
    ical_uid : String? = nil
  ) : JSON::Any
    update_metadata(changes.as_h, original_id, system_id, user_cal, ical_uid, merge: true)
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
    user_cal : String? = nil,
    @[AC::Param::Info(description: "an alternative lookup for finding event-metadata", example: "5FC53010-1267-4F8E-BC28-1D7AE55A7C99")]
    ical_uid : String? = nil
  ) : JSON::Any
    update_metadata(changes.as_h, original_id, system_id, user_cal, ical_uid, merge: false)
  end

  protected def update_metadata(changes : Hash(String, JSON::Any), original_id : String, system_id : String, event_calendar : String?, uuid : String?, merge : Bool = false)
    event_id = original_id
    placeos_client = get_placeos_client

    # Guest access
    if user_token.guest_scope?
      guest_event_id, guest_system_id = user.roles
      system_id ||= guest_system_id
      raise Error::Forbidden.new("guest #{user_token.id} attempting to view a system they are not associated with") unless system_id == guest_system_id
    end

    system = placeos_client.systems.fetch(system_id)
    cal_id = system.email.presence.try &.downcase
    raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless cal_id

    user_email = user_token.guest_scope? ? cal_id : user.email.downcase
    cal_id = event_calendar || cal_id

    # attempt to find the metadata
    query = EventMetadata.by_tenant(tenant.id).where(system_id: system_id)
    if uuid.presence
      query = query.where("ical_uid in (?,?) OR event_id = ?", uuid, event_id, event_id)
    else
      query = query.where(event_id: event_id)
    end

    # if it doesn't exist then we need to fallback to getting the events
    meta = if mdata = query.to_a.first?
             if user_token.guest_scope?
               raise Error::Forbidden.new("guest #{user_token.id} attempting to edit an event they are not associated with") unless merge && guest_event_id.in?({mdata.event_id, mdata.recurring_master_id, mdata.ical_uid})
             elsif mdata.host_email.downcase != user.email.downcase
               # ensure the user should be able to edit this metadata
               confirm_access(system_id)
             end

             mdata
           else
             event = client.get_event(user_email, id: event_id, calendar_id: cal_id)
             raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

             # ensure we have the host event details
             # TODO:: instead of this we should store ical UID in the guest JWT
             if client.client_id == :office365 && event.host.try(&.downcase) != user_email
               begin
                 event = get_hosts_event(event)
                 raise Error::BadUpstreamResponse.new("id must be present on event") unless event_id = event.id
               rescue PlaceCalendar::Exception
                 # we might not have access
               end
             end

             # Guests can update extension_data to indicate their order
             if user_token.guest_scope?
               raise Error::Forbidden.new("guest #{user_token.id} attempting to edit an event they are not associated with") unless merge && guest_event_id.in?({original_id, event_id, event.recurring_event_id})
             else
               attendees = event.attendees.try(&.map { |a| a.email }) || [] of String
               if user_email != event.host.try(&.downcase) && !user_email.in?(attendees)
                 confirm_access(system_id)
               end
             end

             raise Error::BadUpstreamResponse.new("id must be present on system") unless upstream_system_id = system.id
             raise Error::BadUpstreamResponse.new("id must be present on event") unless upstream_event_id = event.id
             raise Error::BadUpstreamResponse.new("ical_uid must be present on event #{upstream_event_id}") unless event_ical_uid = event.ical_uid
             raise Error::BadUpstreamResponse.new("event_start must be present on event") unless event_start = event.event_start
             raise Error::BadUpstreamResponse.new("event_end must be present on event") unless event_end = event.event_end
             raise Error::BadUpstreamResponse.new("email must be present on system") unless system_email = system.email
             raise Error::BadUpstreamResponse.new("host must be present on event") unless event_host = event.host

             # attempt to find the metadata
             mdata = get_migrated_metadata(event, system_id, cal_id) || EventMetadata.new
             mdata.system_id = upstream_system_id
             mdata.event_id = upstream_event_id
             mdata.ical_uid = event_ical_uid
             mdata.recurring_master_id = event.recurring_event_id || event.id if event.recurring
             mdata.event_start = event_start.to_unix
             mdata.event_end = event_end.to_unix
             mdata.resource_calendar = system_email
             mdata.host_email = event_host
             mdata.tenant_id = tenant.id
             mdata
           end

    # Updating extension data by merging into existing.
    if merge && meta.ext_data && (meta_ext_data = meta.ext_data)
      data = meta_ext_data.as_h
      changes.each { |key, value| data[key] = value }
    else
      data = changes
    end

    meta.set_ext_data(JSON::Any.new(data))
    meta.save!

    spawn do
      placeos_client.root.signal("staff/event/changed", {
        action:         :update,
        system_id:      system.id,
        event_id:       original_id,
        event_ical_uid: meta.ical_uid,
        host:           meta.host_email,
        resource:       system.email,
        event:          event,
        ext_data:       meta.ext_data,
      })
    end

    raise Error::InconsistentState.new("ext_data must be present on metadata") unless meta_ext_data = meta.ext_data
    meta_ext_data
  end

  enum ChangeType
    Created
    Updated
    Deleted
  end

  @[AC::Route::POST("/notify/:change/:system_id/:event_id", body: :event, status_code: HTTP::Status::ACCEPTED)]
  def notify_change(
    @[AC::Param::Info(description: "the type of change that has occured", example: "created")]
    change : ChangeType,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    event_id : String,
    event : PlaceCalendar::Event? = nil
  ) : Nil
    system = get_placeos_client.systems.fetch(system_id)

    case change
    in .created?
      raise "no event provided" unless event

      # sleep just in case we're creating the event with metadata
      sleep 0.5
      meta = get_event_metadata(event, system_id, search_recurring: false)
      return if meta
      notify_created_or_updated(:create, system, event, meta)
    in .updated?
      raise "no event provided" unless event
      meta = get_event_metadata(event, system_id, search_recurring: false)

      # we might be just changing the date or time of an individual event
      if meta.nil? && event.recurring_event_id.presence && event.recurring_event_id != event.id
        if rec_meta = EventMetadata.by_tenant(tenant.id).find_by?(event_id: event.recurring_event_id, system_id: system_id)
          meta = EventMetadata.migrate_recurring_metadata(system_id, event, rec_meta)
        end
      end

      notify_created_or_updated(:update, system, event, meta)
    in .deleted?
      meta = if event
               get_event_metadata(event, system_id, search_recurring: false)
             else
               EventMetadata.find_by?(event_id: event_id, system_id: system_id)
             end
      meta.try &.destroy
      notify_destroyed(system, event_id, meta.try &.ical_uid)
    end
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

      raise Error::InconsistentState.new("user_email must be present") unless user_email
      event = client.get_event(user_email, id: event_id, calendar_id: cal_id)
      raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

      # ensure we have the host event details
      # TODO:: instead of this we should store ical UID in the guest JWT
      if client.client_id == :office365 && event.host.try(&.downcase) != cal_id
        begin
          event = get_hosts_event(event)
          raise Error::BadUpstreamResponse.new("id must be present on event") unless event_id = event.id
        rescue PlaceCalendar::Exception
          # we might not have access
        end
      end

      if user_token.guest_scope?
        raise Error::Forbidden.new("guest #{user_token.id} attempting to view an event they are not associated with") unless guest_event_id.in?({original_id, event_id, event.recurring_event_id}) && system_id == guest_system_id
      end

      metadata = get_event_metadata(event, system_id)
      parent_meta = !metadata.try &.for_event_instance?(event, client.client_id)
      StaffApi::Event.augment(event, cal_id, system, metadata, parent_meta)
    else
      # Need to confirm the user can access this calendar
      user_cal = user_cal.try &.downcase
      if user_cal == user.email
        found = true
      elsif user_cal
        found = tenant.delegated || get_user_calendars.reject { |cal| cal.id.try(&.downcase) != user_cal }.first?
      else
        user_cal = user.email
        found = true
      end
      raise Error::Forbidden.new("user #{user.email} is not permitted to view calendar #{user_cal}") unless found && user_cal

      # Grab the event details
      event = client.get_event(user.email, id: event_id, calendar_id: user_cal)
      raise Error::NotFound.new("event #{event_id} not found on calendar #{user_cal}") unless event

      # see if there are any relevent metadata details
      ev_ical_uid = event.ical_uid
      metadata = EventMetadata.by_tenant(tenant.id).where(ical_uid: ev_ical_uid).to_a.first?

      # see if there are any relevent systems associated with the event
      resource_calendars = (event.attendees || StaffApi::Event::NOP_PLACE_CALENDAR_ATTENDEES).compact_map do |attend|
        attend.email if attend.resource
      end

      if !resource_calendars.empty?
        systems = placeos_client.systems.with_emails(resource_calendars)
        if system = systems.first?
          return StaffApi::Event.augment(event, user_cal, system, metadata)
        end
      end

      StaffApi::Event.augment(event, user_cal, metadata: metadata)
    end
  end

  # deletes the event from the calendar, it will not appear as cancelled, it will be gone
  #
  # by default it assumes the event id exists on the users calendar
  # you can clarify the calendar that the event belongs to by using the calendar param
  # and specify a system id if there is event metadata or linked booking associated with the event
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
  #
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

    user_cal = user_cal.try &.strip.downcase
    if user_cal == user.email
      cal_id = user_cal
    elsif user_cal
      cal_id = user_cal
      found = tenant.delegated || get_user_calendars.reject { |cal| cal.id.try(&.downcase) != cal_id }.first?
      raise AC::Route::Param::ValueError.new("user doesn't have write access to #{cal_id}", "calendar") unless found
    end

    if system_id
      system = placeos_client.systems.fetch(system_id)
      sys_cal = system.email.presence.try(&.strip.downcase)
      if cal_id.nil?
        cal_id = sys_cal
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
    if !tenant.delegated
      existing_attendees = event.attendees.try(&.map { |a| a.email.downcase }) || [] of String
      unless user_email == host || user_email.in?(existing_attendees)
        # may be able to delete on behalf of the user
        raise Error::Forbidden.new("user #{user_email} not involved in meeting and no role is permitted to make this change") if !(system && !check_access(user.roles, [system.id] + system.zones).forbidden?)
      end
    end

    # we don't need host details for delete / decline as we want it to occur on the calendar specified
    # unless using a service account and then we can only use the host calendar
    if (srv_acct = tenant.service_account) && client.client_id == :office365 && event.host != cal_id
      original_event = event
      event = get_hosts_event(event, tenant.service_account)
      raise Error::BadUpstreamResponse.new("id must be present on event") unless event_id = event.id
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

    if system && system_id
      get_event_metadata(original_event, system_id, search_recurring: false).try(&.destroy) if original_event
      get_event_metadata(event, system_id, search_recurring: false).try &.destroy

      spawn { notify_destroyed(system, event_id, event.ical_uid, event) }
    end
  end

  # approves / accepts the meeting on behalf of the event space
  @[AC::Route::POST("/:id/approve")]
  def approve(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String
  ) : Bool
    # Check this system has an associated resource
    system = get_placeos_client.systems.fetch(system_id)
    cal_id = system.email
    raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless cal_id
    client.accept_event(cal_id, id: event_id, calendar_id: cal_id)
  end

  # rejects / declines the meeting on behalf of the event space
  @[AC::Route::POST("/:id/reject")]
  def reject(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String
  ) : Bool
    # Check this system has an associated resource
    system = get_placeos_client.systems.fetch(system_id)
    cal_id = system.email
    raise AC::Route::Param::ValueError.new("system '#{system.name}' (#{system_id}) does not have a resource email address specified", "system_id") unless cal_id
    client.decline_event(cal_id, id: event_id, calendar_id: cal_id)
  end

  # Event Guest management
  @[AC::Route::GET("/:id/guests")]
  def guest_list(
    @[AC::Param::Info(name: "id", description: "the event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String,
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String
  ) : Array(Guest | Attendee)
    cal_id = get_placeos_client.systems.fetch(system_id).email
    return [] of Guest | Attendee unless cal_id

    event = client.get_event(user.email, id: event_id, calendar_id: cal_id)
    raise Error::NotFound.new("event #{event_id} not found on system calendar #{cal_id}") unless event

    # Grab meeting metadata if it exists
    metadata = get_event_metadata(event, system_id)
    parent_meta = !metadata.try &.for_event_instance?(event, client.client_id)
    return [] of Guest | Attendee unless metadata

    # Find anyone who is attending
    visitors = metadata.attendees.to_a
    return [] of Guest | Attendee if visitors.empty?

    # Grab the guest profiles if they exist
    guests = visitors.each_with_object({} of String => Guest) do |visitor, obj|
      raise Error::InconsistentState.new("guest must be present on visitor metadata") unless guest = visitor.guest
      raise Error::InconsistentState.new("email must be present on guest") unless guest_email = guest.email
      obj[guest_email] = guest
    end

    # Merge the visitor data with guest profiles
    visitors.map do |visitor|
      raise Error::InconsistentState.new("guest must be present on visitor metadata") unless guest = visitor.guest
      attending_guest(visitor, guests[guest.email]?, parent_meta)
    end
  end

  # This exists to obtain events that have some condition that requires action.
  # i.e. you might have a flag that indicates if an action has taken place and can use this to
  # look up events in certain states.
  # example route: /extension_metadata?field_name=colour&value=blue
  @[AC::Route::GET("/extension_metadata/?:system_id", converters: {event_ref: ConvertStringArray})]
  def extension_metadata(
    @[AC::Param::Info(description: "the event space associated with this event", example: "sys-1234")]
    system_id : String? = nil,
    @[AC::Param::Info(description: "the field we want to query", example: "status")]
    field_name : String? = nil,
    @[AC::Param::Info(description: "value we want to match", example: "approved")]
    value : String? = nil,
    @[AC::Param::Info(name: "period_start", description: "event period start as a unix epoch", example: "1661725146")]
    starting : Int64? = nil,
    @[AC::Param::Info(name: "period_end", description: "event period end as a unix epoch", example: "1661743123")]
    ending : Int64? = nil,
    @[AC::Param::Info(description: "list of event ids that we're potentially", example: "event_id,recurring_event_id,ical_uid")]
    event_ref : Array(String)? = nil
  ) : Array(EventMetadata)
    raise Error::BadRequest.new("must provide one of field_name & value, system_id, event_ref, period_start or period_end") unless system_id || (field_name && value) || starting || ending || (event_ref && event_ref.size > 0)

    query = EventMetadata.by_tenant(tenant.id).is_ending_after(starting).is_starting_before(ending)

    query = query.where(system_id: system_id) if system_id
    query = query.by_event_ids(event_ref) if event_ref && !event_ref.empty?
    if field_name && value.presence
      raise Error::BadRequest.new("must provide both field_name & value") unless value
      query = query.by_ext_data(field_name, value)
    end

    query.limit(10_000).to_a
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
  ) : Guest
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
                    Guest.by_tenant(tenant.id).find(guest_id.to_i64).email
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
      Guest.by_tenant(tenant.id).find_by(email: guest_email)
    rescue PgORM::Error::RecordNotFound
      g = Guest.new(
        tenant_id: tenant.id,
        email: guest_email,
        name: attendee.name,
        banned: false,
        dangerous: false,
        extension_data: JSON::Any.new({} of String => JSON::Any),
      )
      g.save! rescue raise Error::ModelValidation.new(g.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating guest data")
    end

    if user_token.guest_scope?
      raise Error::Forbidden.new("guest #{user_token.id} attempting to view an event they are not associated with") unless guest_event_id.in?({original_id, event_id, event.recurring_event_id})
    end

    raise Error::BadUpstreamResponse.new("id must be present on system") unless meta_system_id = system.id
    raise Error::BadUpstreamResponse.new("id must be present on event") unless meta_event_id = event.id
    raise Error::BadUpstreamResponse.new("event_start must be present on event") unless meta_event_start = event.event_start
    raise Error::BadUpstreamResponse.new("event_end must be present on event") unless meta_event_end = event.event_end
    raise Error::BadUpstreamResponse.new("host must be present on event") unless meta_event_host = event.host
    raise Error::BadUpstreamResponse.new("ical_uid must be present on event") unless meta_event_ical_uid = event.ical_uid

    eventmeta = get_migrated_metadata(event, system_id, cal_id) || EventMetadata.create!(
      system_id: meta_system_id,
      event_id: meta_event_id,
      recurring_master_id: (event.recurring_event_id || event.id if event.recurring),
      event_start: meta_event_start.to_unix,
      event_end: meta_event_end.to_unix,
      resource_calendar: cal_id,
      host_email: meta_event_host,
      tenant_id: tenant.id,
      ical_uid: meta_event_ical_uid,
    )

    raise Error::BadUpstreamResponse.new("id must be present on event metadata") unless eventmeta_id = eventmeta.id

    if attendee = Attendee.by_tenant(tenant.id).find_by?(guest_id: guest.id, event_id: eventmeta_id)
      attendee.update!(checked_in: checkin)
    else
      attendee = Attendee.create!(
        event_id: eventmeta_id,
        guest_id: guest.id,
        visit_expected: true,
        checked_in: checkin,
        tenant_id: tenant.id,
      )
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
        event_ical_uid: eventmeta.ical_uid,
        host:           event.host,
        resource:       eventmeta.resource_calendar,
        event_summary:  event.title,
        event_starting: eventmeta.event_start,
        attendee_name:  guest.name,
        attendee_email: guest.email,
        zones:          system.zones,
      })
    end

    attending_guest(attendee, attendee.guest, false, event).as(Guest)
  end

  # ==========================
  # NOTIFICATIONS
  # ==========================

  def notify_created_or_updated(action, system, event, meta = nil, can_skip = true)
    raise Error::InconsistentState.new("event_start must be present on event") unless event_start = event.event_start
    raise Error::InconsistentState.new("event_end must be present on event") unless event_end = event.event_end

    starting = event_start.to_unix
    ending = event_end.to_unix
    cancelled = event.status == "cancelled"

    skip_signal = can_skip && meta &&
                  meta.system_id == system.id &&
                  meta.event_start == starting &&
                  meta.event_end == ending &&
                  meta.cancelled == cancelled

    meta = meta || EventMetadata.new
    meta.system_id = system.id.as(String)
    meta.event_id = event.id.as(String)
    meta.ical_uid = event.ical_uid.as(String)
    meta.recurring_master_id = event.recurring_event_id || event.id if event.recurring
    meta.event_start = starting
    meta.event_end = ending
    meta.resource_calendar = system.email.as(String).downcase
    meta.host_email = event.host.as(String).downcase
    meta.tenant_id = tenant.id
    meta.cancelled = cancelled

    # create/update setup event
    if meta.setup_time > 0
      if setup_event_id = meta.setup_event_id
        setup_event = client.get_event(meta.resource_calendar, id: setup_event_id, calendar_id: meta.resource_calendar)
        setup_event.start_time = event_start - meta.setup_time
        setup_event.end_time = event_start
      else
        setup_event = client.create_event(
          user_id: meta.resource_calendar,
          calendar_id: meta.resource_calendar,
          subject: "Setup for #{event.subject}",
          start_time: event_start - meta.setup_time,
          end_time: event_start,
        )
        meta.setup_event_id = setup_event.id
      end
    end

    # create/update breakdown event
    if meta.breakdown_time > 0
      if breakdown_event_id = meta.breakdown_event_id
        breakdown_event = client.get_event(meta.resource_calendar, id: breakdown_event_id, calendar_id: meta.resource_calendar)
        breakdown_event.start_time = event_end
        breakdown_event.end_time = event_end + meta.breakdown_time
      else
        breakdown_event = client.create_event(
          user_id: meta.resource_calendar,
          calendar_id: meta.resource_calendar,
          subject: "Breakdown for #{event.subject}",
          start_time: event_end,
          end_time: event_end + meta.breakdown_time,
        )
        meta.breakdown_event_id = breakdown_event.id
      end
    end

    # delete setup/breakdown events if event is cancelled
    if cancelled
      if setup_event_id = meta.setup_event_id
        client.delete_event(
          user_id: meta.resource_calendar,
          id: setup_event_id,
          calendar_id: meta.resource_calendar,
        )
        meta.setup_event_id = nil
      end
      if breakdown_event_id = meta.breakdown_event_id
        client.delete_event(
          user_id: meta.resource_calendar,
          id: breakdown_event_id,
          calendar_id: meta.resource_calendar,
        )
        meta.breakdown_event_id = nil
      end
    end

    meta.save!

    return if skip_signal

    spawn do
      get_placeos_client.root.signal("staff/event/changed", {
        action:         action,
        system_id:      system.id,
        event_id:       meta.event_id,
        event_ical_uid: meta.ical_uid,
        host:           meta.host_email,
        resource:       meta.resource_calendar,
        event:          event,
        ext_data:       meta.try &.ext_data,
      })
    end
  end

  def notify_destroyed(system, event_id, event_ical_uid, event = nil)
    # delete any setup/breakdown events associated with this event
    if meta = EventMetadata.by_tenant(tenant.id).find_by?(event_id: event_id, system_id: system.id)
      if setup_event_id = meta.setup_event_id
        client.delete_event(
          user_id: meta.resource_calendar,
          id: setup_event_id,
          calendar_id: meta.resource_calendar,
        )
      end
      if breakdown_event_id = meta.breakdown_event_id
        client.delete_event(
          user_id: meta.resource_calendar,
          id: breakdown_event_id,
          calendar_id: meta.resource_calendar,
        )
      end
    end

    get_placeos_client.root.signal("staff/event/changed", {
      action:         :cancelled,
      system_id:      system.id,
      event_id:       event_id,
      event_ical_uid: event_ical_uid,
      resource:       system.email,
      event:          event,
    })
  end
end
