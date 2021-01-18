class Guests < Application
  base "/api/staff/v1/guests"

  before_action :find_guest, only: [:show, :update, :update_alt, :destroy, :meetings]
  getter guest : Guest { find_guest }

  # Skip scope check for relevant routes
  skip_action :check_jwt_scope, only: [:show, :update]

  def index
    query = (query_params["q"]? || "").gsub(/[^\w\s]/, "").strip.downcase
    starting = query_params["period_start"]?
    if starting
      period_start = Time.unix(starting.to_i64)
      period_end = Time.unix(query_params["period_end"].to_i64)

      # We want a subset of the calendars
      calendars = matching_calendar_ids
      render(json: [] of Nil) if calendars.empty?

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

      # Don't perform the query if there are no calendar entries
      render(json: [] of Nil) if metadata_ids.empty?

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
        attend.checked_in = false if attend.event_metadata.event_id.in?(metadata_recurring_ids)
        attendees[attend.guest.email] = attend
      end

      render(json: [] of Nil) if attendees.empty?

      guests = {} of String => Guest
      Guest.query
        .by_tenant(tenant.id)
        .where { var("guests", "email").in?(attendees.keys) }
        .each { |guest| guests[guest.email.not_nil!] = guest }

      render json: attendees.map { |email, visitor|
        attending_guest(visitor, guests[email]?)
        # Prevent a database lookup
        meeting_event = nil
        if meet = (meeting_lookup[visitor.event_metadata.event_id]? || meeting_lookup[visitor.event_metadata.ical_uid]?)
          _calendar_id, _system, meeting_event = meet
        end
        attending_guest(visitor, guests[email]?, meeting_details: meeting_event)
      }
    elsif query.empty?
      # Return the first 1500 guests
      render json: Guest.query
        .by_tenant(tenant.id)
        .order_by("name")
        .limit(1500).map { |g| attending_guest(nil, g) }
    else
      # Return guests based on the filter query
      query = "%#{query}%"
      render json: Guest.query
        .by_tenant(tenant.id)
        .where("searchable LIKE :query", query: query)
        .limit(1500).map { |g| attending_guest(nil, g) }
    end
  end

  def show
    if user_token.scope.includes?("guest")
      head :forbidden unless guest.not_nil!.email == user_token.sub
    end

    # find out if they are attending today
    attendee = guest.not_nil!.attending_today(tenant.id, get_timezone)
    render json: attending_guest(attendee, guest)
  end

  def update
    if user_token.scope.includes?("guest")
      head :forbidden unless guest.not_nil!.email == user_token.sub
    end

    parsed = JSON.parse(request.body.not_nil!)
    changes = Guest.new(parsed)
    {% for key in [:name, :preferred_name, :phone, :organisation, :notes, :photo] %}
      begin
        if changes.{{key.id}}_column.defined?
          guest.not_nil!.{{key.id}} = changes.{{key.id}}
        end
      rescue NilAssertionError
      end
    {% end %}

    # For some reason need to manually set the banned and dangerous
    banned = parsed.as_h["banned"]?
    guest.not_nil!.banned = banned.as_bool if banned
    dangerous = parsed.as_h["dangerous"]?
    guest.not_nil!.dangerous = dangerous.as_bool if dangerous

    # merge changes into extension data
    extension_data = parsed.as_h["extension_data"]?
    if extension_data
      guest_ext_data = guest.not_nil!.ext_data
      data = guest_ext_data ? guest_ext_data.as_h : Hash(String, JSON::Any).new
      extension_data.not_nil!.as_h.each { |key, value| data[key] = value }
      # Needed for clear to assign the updated json correctly
      guest.not_nil!.ext_data_column.clear
      guest.not_nil!.ext_data = JSON.parse(data.to_json)
    end

    if guest.not_nil!.save
      attendee = guest.not_nil!.attending_today(tenant.id, get_timezone)
      render json: attending_guest(attendee, guest)
    else
      render :unprocessable_entity, json: guest.not_nil!.errors.map(&.to_s)
    end
  end

  put "/:id", :update_alt { update }

  def create
    parsed = JSON.parse(request.body.not_nil!)
    guest = Guest.new(parsed)
    guest.tenant_id = tenant.id
    banned = parsed.as_h["banned"]?
    guest.not_nil!.banned = banned ? banned.as_bool : false
    dangerous = parsed.as_h["dangerous"]?
    guest.not_nil!.dangerous = dangerous ? dangerous.as_bool : false
    guest.ext_data = parsed.as_h["extension_data"]? || JSON.parse("{}")
    if guest.save
      attendee = guest.attending_today(tenant.id, get_timezone)
      render :created, json: attending_guest(attendee, guest)
    else
      render :unprocessable_entity, json: guest.errors.map(&.to_s)
    end
  end

  # TODO: Should we be allowing to delete guests that are associated with attendees?
  def destroy
    guest.not_nil!.delete
    head :accepted
  end

  get("/:id/meetings", :meetings) do
    future_only = query_params["include_past"]? != "true"
    limit = (query_params["limit"]? || "10").to_i

    placeos_client = get_placeos_client.systems

    events = Promise.all(guest.not_nil!.events(future_only, limit).map { |metadata|
      Promise.defer {
        cal_id = metadata.host_email.not_nil!
        system = placeos_client.fetch(metadata.system_id.not_nil!)
        event = client.get_event(user.email, id: metadata.event_id.not_nil!, calendar_id: cal_id)
        if event
          StaffApi::Event.augment(event.not_nil!, cal_id, system, metadata)
        else
          nil
        end
      }
    }).get.compact
    render json: events
  end

  # ============================================
  #              Helper Methods
  # ============================================

  private def find_guest
    guest = Guest.query
      .by_tenant(tenant.id)
      .find({email: route_params["id"].downcase})
    head(:not_found) unless guest

    guest
  end
end
