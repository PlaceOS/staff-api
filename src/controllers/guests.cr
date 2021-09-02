require "csv"

class Guests < Application
  base "/api/staff/v1/guests"

  getter guest : Guest { find_guest }

  # Skip scope check for relevant routes
  skip_action :check_jwt_scope, only: [:show, :update]

  # ameba:disable Metrics/CyclomaticComplexity
  def index
    query = (query_params["q"]? || "").gsub(/[^\w\s\@\-\.\~\_]/, "").strip.downcase

    if starting = query_params["period_start"]?
      period_start = Time.unix(starting.to_i64)
      period_end = Time.unix(query_params["period_end"].to_i64)

      # Grab the bookings
      booking_lookup = {} of Int64 => Booking::AsHNamedTuple
      booking_ids = Set(Int64).new
      Booking.booked_between(tenant.id, starting.to_i64, query_params["period_end"].to_i64).each do |booking|
        booking_ids << booking.id
        booking_lookup[booking.id] = booking.as_h
      end

      # We want a subset of the calendars
      calendars = matching_calendar_ids
      render(json: [] of Nil) if calendars.empty? && booking_ids.empty?

      # Grab events in batches
      requests = [] of HTTP::Request
      mappings = calendars.map { |calendar_id, system|
        request = client.list_events_request(
          user.email,
          calendar_id,
          period_start: period_start,
          period_end: period_end,
          showDeleted: false
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

      # Grab any existing eventmeta data
      ical_uids = Set(String).new
      metadata_ids = Set(String).new
      metadata_recurring_ids = Set(String).new
      meeting_lookup = {} of String => Tuple(String, PlaceOS::Client::API::Models::System, PlaceCalendar::Event)
      results.each { |(calendar_id, system, event)|
        if system
          ical_uid = event.ical_uid.not_nil!
          ical_uids << ical_uid
          metadata_id = event.id.not_nil!
          metadata_ids << metadata_id
          tuple = {calendar_id, system, event}
          meeting_lookup[ical_uid] = tuple
          meeting_lookup[metadata_id] = tuple
          if event.recurring_event_id && event.id != event.recurring_event_id
            metadata_id = event.recurring_event_id.not_nil!
            metadata_ids << metadata_id
            metadata_recurring_ids << metadata_id
            meeting_lookup[metadata_id] = {calendar_id, system, event}
          end
        end
      }

      # Don't perform the query if there are no calendar or booking entries
      render(json: [] of Nil) if metadata_ids.empty? && booking_ids.empty?

      # Return the guests visiting today
      attendees = {} of String => Attendee

      query = Attendee.query
        .with_guest
        .by_tenant(tenant.id)
        .inner_join("event_metadatas") { var("event_metadatas", "id") == var("attendees", "event_id") }
        .inner_join("guests") { var("guests", "id") == var("attendees", "guest_id") }

      case client.client_id
      when :office365
        query = query.where { event_metadatas.ical_uid.in?(ical_uids.to_a) }
      else
        query = query.where { event_metadatas.event_id.in?(metadata_ids.to_a) }
      end

      query.each do |attend|
        attend.checked_in = false if attend.event_metadata.try &.event_id.try &.in?(metadata_recurring_ids)
        attendees[attend.guest.email] = attend
      end

      booking_attendees = Attendee.by_bookings(tenant.id, booking_ids.to_a)
      booking_attendees.each do |attend|
        attendees[attend.guest.email] = attend
      end

      render(json: [] of Nil) if attendees.empty?

      guests = {} of String => Guest
      Guest.query
        .by_tenant(tenant.id)
        .where { var("guests", "email").in?(attendees.keys) }
        .each { |guest| guests[guest.email.not_nil!] = guest }

      render json: attendees.map { |email, visitor|
        # Prevent a database lookup
        meeting_event = nil
        if meet = (meeting_lookup[visitor.event_metadata.try &.event_id]? || meeting_lookup[visitor.event_metadata.try &.ical_uid]?)
          _calendar_id, _system, meeting_event = meet
        end

        guest = guests[email]?
        if visitor.for_booking?
          if !guest.nil?
            guest.for_booking_to_h(visitor, booking_lookup[visitor.booking_id]?)
          end
        else
          attending_guest(visitor, guest, meeting_details: meeting_event)
        end
      }
    elsif query.empty?
      # Return the first 1500 guests
      render json: Guest.query
        .by_tenant(tenant.id)
        .order_by("name")
        .limit(1500).map { |g| attending_guest(nil, g) }
    else
      # Return guests based on the filter query
      csv = CSV.new(query, strip: true, separator: ' ')
      csv.next
      parts = csv.row.to_a

      sql_query = Guest.query.by_tenant(tenant.id)
      parts.each do |part|
        next if part.empty?
        sql_query = sql_query.where("searchable LIKE :query", query: "#{part}%")
      end

      render json: sql_query.order_by("name").limit(1500).map { |g| attending_guest(nil, g) }
    end
  end

  def show
    if user_token.scope.includes?("guest") && (guest.email != user_token.id)
      head :forbidden
    end

    # find out if they are attending today
    attendee = guest.attending_today(tenant.id, get_timezone)
    result = !attendee.nil? && attendee.for_booking? ? guest.for_booking_to_h(attendee, attendee.booking.try(&.as_h)) : attending_guest(attendee, guest)
    render json: result
  end

  def update
    if user_token.scope.includes?("guest") && (guest.email != user_token.id)
      head :forbidden
    end

    changes = Guest.from_json(request.body.as(IO))
    {% for key in %i(email name preferred_name phone organisation notes photo dangerous banned) %}
      begin
        guest.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
      rescue NilAssertionError
      end
    {% end %}

    extension_data = changes.extension_data if changes.extension_data_column.defined?
    if extension_data
      guest_ext_data = guest.extension_data
      data = guest_ext_data ? guest_ext_data.as_h : Hash(String, JSON::Any).new
      extension_data.not_nil!.as_h.each { |key, value| data[key] = value }
      # Needed for clear to assign the updated json correctly
      guest.extension_data_column.clear
      guest.extension_data = JSON::Any.new(data)
    end

    render :unprocessable_entity, json: guest.errors.map(&.to_s) if !guest.save

    attendee = guest.attending_today(tenant.id, get_timezone)
    render json: attending_guest(attendee, guest)
  end

  put "/:id", :update_alt { update }

  def create
    guest = Guest.from_json(request.body.as(IO))
    guest.tenant_id = tenant.id

    render :unprocessable_entity, json: guest.errors.map(&.to_s) if !guest.save

    attendee = guest.attending_today(tenant.id, get_timezone)
    render :created, json: attending_guest(attendee, guest)
  end

  # TODO: Should we be allowing to delete guests that are associated with attendees?
  def destroy
    guest.delete
    head :accepted
  end

  get("/:id/meetings", :meetings) do
    future_only = query_params["include_past"]? != "true"
    limit = (query_params["limit"]? || "10").to_i

    placeos_client = get_placeos_client.systems

    events = Promise.all(guest.events(future_only, limit).map { |metadata|
      Promise.defer {
        begin
          cal_id = metadata.host_email.not_nil!
          system = placeos_client.fetch(metadata.system_id.not_nil!)
          sys_cal = system.email.presence
          event = client.get_event(user.email, id: metadata.event_id.not_nil!, calendar_id: cal_id)
          if event
            if sys_cal && client.client_id == :office365 && event.host != sys_cal
              event = get_hosts_event(event, sys_cal)
            end

            StaffApi::Event.augment(event.not_nil!, cal_id, system, metadata)
          else
            nil
          end
        rescue error
          Log.warn(exception: error) { error.message }
          nil
        end
      }
    }).get.compact

    render json: events
  end

  get("/:id/bookings", :bookings) do
    if user_token.scope.includes?("guest") && (guest.email != user_token.id)
      head :forbidden
    end

    future_only = query_params["include_past"]? != "true"
    limit = (query_params["limit"]? || "10").to_i

    render json: guest.bookings(future_only, limit).map { |booking| booking.as_h }
  end

  # ============================================
  #              Helper Methods
  # ============================================

  private def find_guest
    guest_id = route_params["id"]
    if guest_id.includes?('@')
      Guest.query.by_tenant(tenant.id).find!({email: guest_id.downcase})
    else
      Guest.query.by_tenant(tenant.id).find!(guest_id.to_i64)
    end
  end
end
