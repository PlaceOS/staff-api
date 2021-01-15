class Bookings < Application
  base "/api/staff/v1/bookings"

  before_action :find_booking, only: [:show, :update, :update_alt, :destroy, :check_in, :approve, :reject]
  before_action :check_access, only: [:update, :update_alt, :destroy, :check_in]
  getter booking : Booking { find_booking }

  def index
    starting = query_params["period_start"].to_i64
    ending = query_params["period_end"].to_i64
    booking_type = query_params["type"]
    zones = Set.new((query_params["zones"]? || "").split(',').map(&.strip).reject(&.empty?)).to_a
    user_id = query_params["user"]?
    user_id = user_token.id if user_id == "current" || (user_id.nil? && zones.empty?)
    user_email = query_params["email"]?

    results = Booking.query
      .by_zones(zones)
      .by_tenant(tenant.id)
      .by_user_id(user_id)
      .by_user_email(user_email)
      .where(
        "booking_start <= :ending AND booking_end >= :starting AND booking_type = :booking_type",
        {starting: starting, ending: ending, booking_type: booking_type})
      .order_by("booking_start", "DESC")
      .limit(20000)
      .to_a.map { |b| b.as_json }

    render json: results
  end

  def create
    parsed = JSON.parse(request.body.not_nil!)
    booking = Booking.new(parsed)

    unless booking.booking_start_column.defined? &&
           booking.booking_end_column.defined? &&
           booking.booking_type_column.defined? &&
           booking.asset_id_column.defined?
      head :bad_request
    end

    # check there isn't a clashing booking
    starting = booking.booking_start
    ending = booking.booking_end
    booking_type = booking.booking_type
    asset_id = booking.asset_id

    existing = Booking.query
      .by_tenant(tenant.id)
      .where(
        "booking_start <= :ending AND booking_end >= :starting AND booking_type = :booking_type AND asset_id = :asset_id",
        {starting: starting, ending: ending, booking_type: booking_type, asset_id: asset_id}
      ).to_a

    head(:conflict) unless existing.empty?

    # Add the tenant details
    booking.tenant_id = tenant.id

    # Add the user details
    booking.user_id = user_token.id
    booking.user_email = user.email
    booking.user_name = user.name

    # Extension data
    booking.ext_data = parsed.as_h["extension_data"]? || JSON.parse("{}")

    # Add missing defaults if any
    checked_in = parsed.as_h["checked_in"]?
    booking.not_nil!.checked_in = checked_in ? checked_in.as_bool : false
    rejected = parsed.as_h["rejected"]?
    booking.not_nil!.rejected = rejected ? rejected.as_bool : false
    approved = parsed.as_h["approved"]?
    booking.not_nil!.approved = approved ? approved.as_bool : false
    zones = parsed.as_h["zones"]?
    booking.not_nil!.zones = zones ? zones.as_a.map { |z| z.as_s } : [] of String

    if booking.save
      spawn do
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
        })
      end

      render json: booking.as_json, status: HTTP::Status::CREATED
    else
      render json: booking.errors.map(&.to_s), status: :unprocessable_entity
    end
  end

  def update
    parsed = JSON.parse(request.body.not_nil!)
    changes = Booking.new(parsed)
    existing_booking = booking.not_nil!

    {% for key in [:asset_id, :zones, :booking_start, :booking_end, :title, :description] %}
      begin
        if changes.{{key.id}}_column.defined?
          existing_booking.{{key.id}} = changes.{{key.id}}
        end
      rescue NilAssertionError
      end
    {% end %}

    # merge changes into extension data
    extension_data = parsed.as_h["extension_data"]?
    if extension_data
      booking_ext_data = booking.not_nil!.ext_data
      data = booking_ext_data ? booking_ext_data.as_h : Hash(String, JSON::Any).new
      extension_data.not_nil!.as_h.each { |key, value| data[key] = value }
      # Needed for clear to assign the updated json correctly
      existing_booking.ext_data_column.clear
      existing_booking.ext_data = JSON.parse(data.to_json)
    end

    # reset the checked-in state
    existing_booking.checked_in = false
    existing_booking.rejected = false
    existing_booking.approved = false

    # check there isn't a clashing booking
    starting = existing_booking.booking_start
    ending = existing_booking.booking_end
    booking_type = existing_booking.booking_type
    asset_id = existing_booking.asset_id

    existing = Booking.query
      .by_tenant(tenant.id)
      .where(
        "booking_start <= :ending AND booking_end >= :starting AND booking_type = :booking_type AND asset_id = :asset_id",
        {starting: starting, ending: ending, booking_type: booking_type, asset_id: asset_id}
      ).to_a

    # Don't clash with self
    existing = existing.reject { |b| b.id == existing_booking.id }

    head(:conflict) unless existing.empty?

    update_booking(existing_booking)
  end

  def show
    render json: booking.not_nil!.as_json
  end

  def destroy
    booking_ref = booking.not_nil!
    booking_ref.delete

    spawn do
      get_placeos_client.root.signal("staff/booking/changed", {
        action:        :cancelled,
        id:            booking_ref.id,
        booking_type:  booking_ref.booking_type,
        booking_start: booking_ref.booking_start,
        booking_end:   booking_ref.booking_end,
        timezone:      booking_ref.timezone,
        resource_id:   booking_ref.asset_id,
        user_id:       booking_ref.user_id,
        user_email:    booking_ref.user_email,
        user_name:     booking_ref.user_name,
        zones:         booking_ref.zones,
      })
    end

    head :accepted
  end

  post "/:id/approve", :approve do
    set_approver(booking.not_nil!, true)
    update_booking(booking.not_nil!, "approved")
  end

  post "/:id/reject", :reject do
    set_approver(booking.not_nil!, false)
    update_booking(booking.not_nil!, "rejected")
  end

  post "/:id/check_in", :check_in do
    booking.not_nil!.checked_in = params["state"]? != "false"
    update_booking(booking.not_nil!, "checked_in")
  end

  # ============================================
  #              Helper Methods
  # ============================================

  def find_booking
    booking = Booking.query
      .by_tenant(tenant.id)
      .find({id: route_params["id"].to_i64})

    render :not_found, json: {error: "booking id #{route_params["id"]} not found"} unless booking

    booking
  end

  def check_access
    user = user_token
    if booking && booking.not_nil!.user_id != user.id
      head :forbidden unless user.is_admin? || user.is_support?
    end
  end

  def update_booking(booking, signal = "changed")
    if booking.save
      spawn do
        get_placeos_client.root.signal("staff/booking/changed", {
          action:        signal,
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
        })
      end

      render json: booking.as_json
    else
      render json: booking.errors.map(&.to_s), status: :unprocessable_entity
    end
  end

  def set_approver(booking, approved : Bool)
    # In case of rejections reset approver related information
    booking.approver_id = approved ? user_token.id : nil
    booking.approver_email = approved ? user.email : nil
    booking.approver_name = approved ? user.name : nil
    booking.approved = approved
    booking.rejected = !approved
  end
end
