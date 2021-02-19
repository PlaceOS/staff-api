class Bookings < Application
  base "/api/staff/v1/bookings"

  before_action :confirm_access, only: [:update, :update_alt, :destroy, :update_state]
  getter booking : Booking { find_booking }

  def index
    starting = query_params["period_start"].to_i64
    ending = query_params["period_end"].to_i64
    booking_type = query_params["type"]
    booking_state = query_params["state"]?
    zones = Set.new((query_params["zones"]? || "").split(',').map(&.strip).reject(&.empty?)).to_a
    user_email = query_params["email"]?
    user_id = query_params["user"]?
    user_id = user_token.id if user_id == "current" || (user_id.nil? && zones.empty? && user_email.nil?)
    created_before = query_params["created_before"]?
    created_after = query_params["created_after"]?
    approved = query_params["approved"]?
    rejected = query_params["rejected"]?

    query = Booking.query
      .by_tenant(tenant.id)
      .by_zones(zones)
      .by_user_id(user_id)
      .by_user_email(user_email)
      .booking_state(booking_state)
      .created_before(created_before)
      .created_after(created_after)
      .is_approved(approved)
      .is_rejected(rejected)
      .where(
        "booking_start <= :ending AND booking_end >= :starting AND booking_type = :booking_type",
        starting: starting, ending: ending, booking_type: booking_type)
      .order_by(:booking_start, :desc)
      .limit(20000)

    response.headers["x-placeos-rawsql"] = query.to_sql

    results = query.to_a.map { |b| b.as_json }

    render json: results
  end

  def create
    parsed = JSON.parse(request.body.not_nil!).as_h
    booking = Booking.new(parsed)

    head :bad_request unless booking.booking_start_column.defined? &&
                             booking.booking_end_column.defined? &&
                             booking.booking_type_column.defined? &&
                             booking.asset_id_column.defined?

    # check there isn't a clashing booking
    clashing_bookings = check_clashing(booking)
    render :conflict, json: clashing_bookings.first if clashing_bookings.size > 0

    # Add the tenant details
    booking.tenant_id = tenant.id

    # Add the user details
    booking.booked_by_id = user_token.id
    booking.booked_by_email = user.email
    booking.booked_by_name = user.name

    booking.user_id = booking.booked_by_id if !booking.user_id_column.defined?
    booking.user_email = booking.booked_by_email if !booking.user_email_column.defined?
    booking.user_name = booking.booked_by_name if !booking.user_name_column.defined?

    # Extension data
    booking.ext_data = parsed["extension_data"]? || JSON.parse("{}")

    if booking.save
      spawn do
        begin
          get_placeos_client.root.signal("staff/booking/changed", {
            action:        :create,
            id:            booking.id,
            booking_type:  booking.booking_type,
            booking_start: booking.booking_start,
            booking_end:   booking.booking_end,
            timezone:      booking.timezone,
            resource_id:   booking.asset_id,
            user_id:       booking.user_id,
            user_email:    booking.user_email,
            user_name:     booking.user_name,
            zones:         booking.zones,
            process_state: booking.process_state,
            last_changed:  booking.last_changed,
            title:         booking.title,
            checked_in:    booking.checked_in,
            description:   booking.description,
          })
        rescue error
          Log.error(exception: error) { "while signaling booking created" }
        end
      end

      render :created, json: booking.as_json
    else
      render :unprocessable_entity, json: booking.errors.map(&.to_s)
    end
  end

  def update
    parsed = JSON.parse(request.body.not_nil!)
    changes = Booking.new(parsed)
    existing_booking = booking

    {% for key in [:asset_id, :zones, :booking_start, :booking_end, :title, :description] %}
      begin
        existing_booking.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
      rescue NilAssertionError
      end
    {% end %}

    # merge changes into extension data
    extension_data = parsed.as_h["extension_data"]?
    if extension_data
      booking_ext_data = booking.ext_data
      data = booking_ext_data ? booking_ext_data.as_h : Hash(String, JSON::Any).new
      extension_data.not_nil!.as_h.each { |key, value| data[key] = value }
      # Needed for clear to assign the updated json correctly
      existing_booking.ext_data_column.clear
      existing_booking.ext_data = JSON.parse(data.to_json)
    end

    # reset the checked-in state
    reset_state = existing_booking.asset_id_column.changed? || existing_booking.booking_start_column.changed? || existing_booking.booking_end_column.changed?
    if reset_state
      existing_booking.set({
        checked_in:   false,
        rejected:     false,
        approved:     false,
        last_changed: Time.utc.to_unix,
      })
    end

    # check there isn't a clashing booking
    clashing_bookings = check_clashing(existing_booking)
    render :conflict, json: clashing_bookings.first if clashing_bookings.size > 0

    update_booking(existing_booking, reset_state ? "changed" : "metadata_changed")
  end

  def show
    render json: booking.as_json
  end

  def destroy
    booking.delete

    spawn do
      begin
        get_placeos_client.root.signal("staff/booking/changed", {
          action:        :cancelled,
          id:            booking.id,
          booking_type:  booking.booking_type,
          booking_start: booking.booking_start,
          booking_end:   booking.booking_end,
          timezone:      booking.timezone,
          resource_id:   booking.asset_id,
          user_id:       booking.user_id,
          user_email:    booking.user_email,
          user_name:     booking.user_name,
          zones:         booking.zones,
          process_state: booking.process_state,
          last_changed:  booking.last_changed,
          title:         booking.title,
          checked_in:    booking.checked_in,
          description:   booking.description,
        })
      rescue error
        Log.error(exception: error) { "while signaling booking cancelled" }
      end
    end

    head :accepted
  end

  # we don't enforce permissions on these as peoples managers can perform these actions
  post "/:id/approve", :approve do
    set_approver(booking, true)

    clashing_bookings = check_clashing(booking)
    render :conflict, json: clashing_bookings.first if clashing_bookings.size > 0

    update_booking(booking, "approved")
  end

  post "/:id/reject", :reject do
    set_approver(booking, false)
    update_booking(booking, "rejected")
  end

  post "/:id/check_in", :check_in do
    booking.checked_in = params["state"]? != "false"
    update_booking(booking, "checked_in")
  end

  post "/:id/update_state", :update_state do
    booking.process_state = params["state"]?
    update_booking(booking, "process_state")
  end

  # ============================================
  #              Helper Methods
  # ============================================
  private def check_clashing(new_booking)
    # check there isn't a clashing booking
    starting = new_booking.booking_start
    ending = new_booking.booking_end
    booking_type = new_booking.booking_type
    asset_id = new_booking.asset_id

    query = Booking.query
      .by_tenant(tenant.id)
      .where(
        "booking_start <= :ending AND booking_end >= :starting AND booking_type = :booking_type AND asset_id = :asset_id AND rejected = FALSE",
        starting: starting, ending: ending, booking_type: booking_type, asset_id: asset_id
      )
    query = query.where { id != new_booking.id } if new_booking.id_column.defined?
    query.to_a
  end

  private def find_booking
    Booking.query
      .by_tenant(tenant.id)
      .find!({id: route_params["id"].to_i64})
  end

  private def confirm_access
    if (user = user_token) &&
       (booking && booking.user_id != user.id) &&
       !(user.is_admin? || user.is_support?) &&
       !check_access(user.user.roles, booking.zones || [] of String).none?
      head :forbidden
    end
  end

  private def update_booking(booking, signal = "changed")
    if booking.save
      spawn do
        begin
          get_placeos_client.root.signal("staff/booking/changed", {
            action:         signal,
            id:             booking.id,
            booking_type:   booking.booking_type,
            booking_start:  booking.booking_start,
            booking_end:    booking.booking_end,
            timezone:       booking.timezone,
            resource_id:    booking.asset_id,
            user_id:        booking.user_id,
            user_email:     booking.user_email,
            user_name:      booking.user_name,
            zones:          booking.zones,
            process_state:  booking.process_state,
            last_changed:   booking.last_changed,
            approver_name:  booking.approver_name,
            approver_email: booking.approver_email,
            title:          booking.title,
            checked_in:     booking.checked_in,
            description:    booking.description,
          })
        rescue error
          Log.error(exception: error) { "while signaling booking #{signal}" }
        end
      end

      render json: booking.as_json
    else
      render :unprocessable_entity, json: booking.errors.map(&.to_s)
    end
  end

  private def set_approver(booking, approved : Bool)
    # In case of rejections reset approver related information
    booking.approver_id = approved ? user_token.id : nil
    booking.approver_email = approved ? user.email : nil
    booking.approver_name = approved ? user.name : nil
    booking.approved = approved
    booking.rejected = !approved
  end
end
