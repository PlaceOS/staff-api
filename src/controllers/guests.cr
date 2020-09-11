class Guests < Application
  base "/api/staff/v1/guests"

  before_action :find_guest, only: [:show, :update, :update_alt, :destroy, :meetings]
  getter guest : Guest { find_guest }

  # Skip scope check for relevant routes
  skip_action :check_jwt_scope, only: [:show, :update]

  def index
    query = (query_params["q"]? || "").gsub(/[^\w\s]/, "").strip.downcase
    period_start = query_params["period_start"]?
    if period_start
      starting = period_start.to_i64
      ending = query_params["period_end"].to_i64

      # Return the guests visiting today
      attendees = {} of String => Attendee

      # We want a subset of the calendars
      if query_params["zone_ids"]? || query_params["system_ids"]?
        system_ids = matching_calendar_ids.values.map(&.try(&.id))
        render(json: [] of Nil) if system_ids.empty?

        Attendee.query
          .with_guest
          .by_tenant(tenant.id)
          .inner_join("event_metadatas") { var("event_metadatas", "id") == var("attendees", "event_id") }
          .inner_join("guests") { var("guests", "id") == var("attendees", "guest_id") }
          .where("event_metadatas.event_start <= :ending AND event_metadatas.event_end >= :starting", {starting: starting, ending: ending})
          .where { event_metadatas.system_id.in?(system_ids) }
          .each { |attendee| attendees[attendee.guest.email] = attendee }
      else
        Attendee.query
          .with_guest
          .by_tenant(tenant.id)
          .inner_join("event_metadatas") { var("event_metadatas", "id") == var("attendees", "event_id") }
          .inner_join("guests") { var("guests", "id") == var("attendees", "guest_id") }
          .where("event_metadatas.event_start <= :ending AND event_metadatas.event_end >= :starting", {starting: starting, ending: ending})
          .each { |attendee| attendees[attendee.guest.email] = attendee }
      end

      render(json: [] of Nil) if attendees.empty?

      guests = {} of String => Guest
      Guest.query
        .by_tenant(tenant.id)
        .where { var("guests", "email").in?(attendees.keys) }
        .each { |guest| guests[guest.email.not_nil!] = guest }

      render json: attendees.map { |email, visitor| attending_guest(visitor, guests[email]?) }
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
        .where("searchable LIKE :query", {query: query})
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
      guest.not_nil!.ext_data = JSON.parse(data.to_json)
    end

    if guest.not_nil!.save
      attendee = guest.not_nil!.attending_today(tenant.id, get_timezone)
      render json: attending_guest(attendee, guest), status: HTTP::Status::OK
    else
      render json: guest.not_nil!.errors.map(&.to_s), status: :unprocessable_entity
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
      render json: attending_guest(attendee, guest), status: HTTP::Status::CREATED
    else
      render json: guest.errors.map(&.to_s), status: :unprocessable_entity
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
        cal_id = metadata.resource_calendar.not_nil!
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

  def find_guest
    guest = Guest.query
      .by_tenant(tenant.id)
      .find({email: route_params["id"].downcase})
    head(:not_found) unless guest

    guest
  end
end
