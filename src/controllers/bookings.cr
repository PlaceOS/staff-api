class Bookings < Application
  base "/api/staff/v1/bookings"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:around_action, only: [:create, :update])]
  def wrap_in_transaction(&)
    PgORM::Database.transaction do
      yield
    end
  end

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_booking(id : Int64)
    @booking = Booking
      .by_tenant(tenant.id)
      .find(id)
  end

  @[AC::Route::Filter(:before_action, only: [:update, :update_alt, :destroy, :update_state])]
  private def confirm_access
    if (user = user_token) &&
       (booking && !({booking.user_id, booking.booked_by_id}.includes?(user.id) || (booking.user_email == user_token.user.email.downcase))) &&
       !(user.is_admin? || user.is_support?) &&
       !check_access(user.user.roles, booking.zones || [] of String).none?
      head :forbidden
    end
  end

  @[AC::Route::Filter(:before_action, only: [:approve, :reject, :check_in, :guest_checkin])]
  private def check_deleted
    head :method_not_allowed if booking.deleted
  end

  getter! booking : Booking

  # =====================
  # Exception Handlers
  # =====================

  # returned when there is a booking clash or limit reached
  struct BookingError
    include JSON::Serializable
    include YAML::Serializable

    getter error : String
    getter limit : Int32? = nil
    getter bookings : Array(Booking)? = nil

    def initialize(@error, @limit = nil, @bookings = nil)
    end
  end

  # 409 if clashing booking
  @[AC::Route::Exception(Error::BookingConflict, status_code: HTTP::Status::CONFLICT)]
  def booking_conflict(error) : BookingError
    Log.debug { error.message }
    BookingError.new(error.message.not_nil!, bookings: error.bookings)
  end

  # 410 if booking limit reached
  @[AC::Route::Exception(Error::BookingLimit, status_code: HTTP::Status::GONE)]
  def booking_limit_reached(error) : BookingError
    Log.debug { error.message }
    BookingError.new(error.message.not_nil!, error.limit, error.bookings)
  end

  # =====================
  # Routes
  # =====================

  PARAMS = %w(booking_type checked_in created_before created_after approved rejected extension_data state department)

  # lists bookings based on the parameters provided
  #
  # booking_type is required unless event_id or ical_uid is present
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "period_start", description: "booking period start as a unix epoch", example: "1661725146")]
    starting : Int64 = Time.utc.to_unix,
    @[AC::Param::Info(name: "period_end", description: "booking period end as a unix epoch", example: "1661743123")]
    ending : Int64 = 1.hours.from_now.to_unix,
    @[AC::Param::Info(name: "type", description: "the generic name of the asset whose bookings you wish to view", example: "desk")]
    booking_type : String? = nil,
    @[AC::Param::Info(name: "deleted", description: "when true, it returns deleted bookings", example: "true")]
    deleted_flag : Bool = false,
    @[AC::Param::Info(description: "when true, returns all bookings including checked out ones", example: "true")]
    include_checked_out : Bool = false,
    @[AC::Param::Info(name: "checked_out", description: "when true, only returns checked out bookings, unless `include_checked_out=true`", example: "true")]
    checked_out_flag : Bool = false,
    @[AC::Param::Info(description: "this filters only bookings in the zones provided, multiple zones can be provided comma seperated", example: "zone-123,zone-456")]
    zones : String? = nil,
    @[AC::Param::Info(name: "email", description: "filters bookings owned by this user email", example: "user@org.com")]
    user_email : String? = nil,
    @[AC::Param::Info(name: "user", description: "filters bookings owned by this user id", example: "user-1234")]
    user_id : String? = nil,
    @[AC::Param::Info(description: "if `email` or `user` parameters are set, this includes bookings that user booked on behalf of others", example: "true")]
    include_booked_by : Bool? = nil,

    @[AC::Param::Info(description: "filters bookings that have been checked in or not", example: "true")]
    checked_in : Bool? = nil,
    @[AC::Param::Info(description: "filters bookings that were created before the unix epoch specified", example: "1661743123")]
    created_before : Int64? = nil,
    @[AC::Param::Info(description: "filters bookings that were created after the unix epoch specified", example: "1661743123")]
    created_after : Int64? = nil,
    @[AC::Param::Info(description: "filters bookings that are approved or not", example: "true")]
    approved : Bool? = nil,
    @[AC::Param::Info(description: "filters bookings that are rejected or not", example: "true")]
    rejected : Bool? = nil,
    @[AC::Param::Info(description: "filters bookings with matching extension data entries", example: %({"entry1":"value to match","entry2":1234}))]
    extension_data : String? = nil,
    @[AC::Param::Info(description: "filters on the booking process state, a user defined value", example: "pending-approval")]
    state : String? = nil,
    @[AC::Param::Info(description: "filters bookings owned by a department, a user defined value", example: "accounting")]
    department : String? = nil,

    @[AC::Param::Info(description: "filters bookings associated with an event, such as an Office365 Calendar event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String? = nil,
    @[AC::Param::Info(description: "filters bookings associated with an event, such as an Office365 Calendar event ical_uid", example: "19rh93h5t893h5v@calendar.iCloud.com")]
    ical_uid : String? = nil,
    @[AC::Param::Info(description: "the maximum number of results to return", example: "10000")]
    limit : Int32 = 100,
    @[AC::Param::Info(description: "the starting offset of the result set. Used to implement pagination")]
    offset : Int32 = 0
  ) : Array(Booking)
    query = Booking.by_tenant(tenant.id)
    event_ids = [event_id.presence, ical_uid.presence].compact

    if event_ids.empty?
      raise AC::Route::Param::MissingError.new("missing required parameter", "booking_type", "String") unless booking_type.presence

      query = query.where(
        %("booking_start" < ? AND "booking_end" > ?),
        ending, starting
      )

      zones = Set.new((zones || "").split(',').map(&.strip).reject(&.empty?)).to_a
      query = query.by_zones(zones) unless zones.empty?

      # We want to do a special current user query if no user details are provided
      if user_id == "current" || (user_id.nil? && zones.empty? && user_email.nil?)
        user_id = user_token.id
        user_email = user.email
      end

      query = query.by_user_or_email(user_id, user_email, include_booked_by)
    else
      id_query = "ARRAY['#{event_ids.map(&.gsub(/['";]/, "")).join(%(','))}']"
      metadata_ids = EventMetadata.where(
        %["tenant_id" = ? AND ("event_id" = ANY (#{id_query}) OR "ical_uid" = ANY (#{id_query}))],
        tenant.id
      ).ids

      return [] of Booking if metadata_ids.empty?
      query = query.where({:event_id => metadata_ids})
    end

    {% for param in PARAMS %}
      if !{{param.id}}.nil?
        query = query.is_{{param.id}}({{param.id}})
      end
    {% end %}

    query = query.where(deleted: deleted_flag)

    unless include_checked_out
      query = checked_out_flag ? query.where("checked_out_at != ?", nil) : query.where(checked_out_at: nil)
    end

    total = query.count
    range_start = offset > 0 ? offset - 1 : 0

    query = query
      .order(booking_start: :desc)
      .offset(range_start)
      .limit(limit)

    result = query.to_a
    range_end = result.size + range_start

    response.headers["X-Total-Count"] = total.to_s
    response.headers["Content-Range"] = "bookings #{offset}-#{range_end}/#{total}"

    # Set link
    if range_end < total
      params["offset"] = (range_end + 1).to_s
      params["limit"] = limit.to_s
      response.headers["Link"] = %(<#{base_route}?#{params}>; rel="next")
    end

    response.headers["x-placeos-rawsql"] = query.to_sql
    result
  end

  # creates a new booking
  @[AC::Route::POST("/", body: :booking, status_code: HTTP::Status::CREATED)]
  def create(
    booking : Booking,

    @[AC::Param::Info(description: "provided for use with analytics", example: "mobile")]
    utm_source : String? = nil,
    @[AC::Param::Info(description: "allows a client to override any limits imposed on bookings", example: "3")]
    limit_override : Int32? = nil,

    @[AC::Param::Info(description: "links booking with an event, such as an Office365 Calendar event id", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String? = nil,
    @[AC::Param::Info(description: "links booking with an event, such as an Office365 Calendar event ical_uid", example: "19rh93h5t893h5v@calendar.iCloud.com")]
    ical_uid : String? = nil
  ) : Booking
    unless booking.booking_start_present? &&
           booking.booking_end_present? &&
           booking.booking_type_present? &&
           booking.asset_id_present?
      raise Error::ModelValidation.new([{field: nil.as(String?), reason: "Missing one of booking_start, booking_end, booking_type or asset_id"}], "error validating booking data")
    end

    # check there isn't a clashing booking
    clashing_bookings = check_clashing(booking)
    raise Error::BookingConflict.new(clashing_bookings) if clashing_bookings.size > 0

    event_ids = [event_id.presence, ical_uid.presence].compact
    if !event_ids.empty?
      id_query = "ARRAY['#{event_ids.map(&.gsub(/['";]/, "")).join(%(','))}']"
      metadata_ids = EventMetadata.where(
        %["tenant_id" = ? AND ("event_id" = ANY (#{id_query}) OR "ical_uid" = ANY (#{id_query}))],
        tenant.id
      ).ids

      raise Error::ModelValidation.new([{field: "event_id".as(String?), reason: "Could not find metadata for event #{id_query}"}], "error linking booking to event") if metadata_ids.empty?
      booking.event_id = metadata_ids.first
    end

    # Add utm_source
    booking.utm_source = utm_source

    # Add the tenant details
    booking.tenant_id = tenant.id.not_nil!

    # clear history
    booking.history = [] of Booking::History

    # Add the user details
    booking.booked_by_id = user_token.id
    booking.booked_by_email = PlaceOS::Model::Email.new(user.email)
    booking.booked_by_name = user.name

    attendees = booking.req_attendees

    if attendees && !attendees.empty?
      attendees.each do |attendee|
        unless attendee.response_status
          attendee.response_status = "needsAction"
        end
      end
    end

    # check concurrent bookings don't exceed booking limits
    check_booking_limits(tenant, booking, limit_override)
    booking.save! rescue raise Error::ModelValidation.new(booking.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating booking data")

    # Grab the list of attendees
    attending = booking.req_attendees

    if attending && !attending.empty?
      # Create guests
      attending.each do |attendee|
        email = attendee.email.strip.downcase

        guest = if existing_guest = Guest.by_tenant(tenant.id).find_by?(email: email)
                  existing_guest.name = attendee.name if existing_guest.name != attendee.name
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
        Attendee.create!(
          booking_id: booking.id.not_nil!,
          guest_id: guest.id,
          visit_expected: true,
          checked_in: attendee.checked_in || false,
          tenant_id: tenant.id,
        )

        spawn do
          get_placeos_client.root.signal("staff/guest/attending", {
            action:         :booking_created,
            id:             guest.id,
            booking_id:     booking.id,
            resource_id:    booking.asset_id,
            event_summary:  booking.title,
            event_starting: booking.booking_start,
            attendee_name:  guest.name,
            attendee_email: guest.email,
            host:           booking.user_email,
            zones:          booking.zones,
          })
        end
      end
    end

    spawn do
      begin
        get_placeos_client.root.signal("staff/booking/changed", {
          action:          :create,
          id:              booking.id,
          booking_type:    booking.booking_type,
          booking_start:   booking.booking_start,
          booking_end:     booking.booking_end,
          timezone:        booking.timezone,
          resource_id:     booking.asset_id,
          user_id:         booking.user_id,
          user_email:      booking.user_email,
          user_name:       booking.user_name,
          zones:           booking.zones,
          process_state:   booking.process_state,
          last_changed:    booking.last_changed,
          title:           booking.title,
          checked_in:      booking.checked_in,
          description:     booking.description,
          extension_data:  booking.extension_data,
          booked_by_email: booking.booked_by_email,
          booked_by_name:  booking.booked_by_name,
        })
      rescue error
        Log.error(exception: error) { "while signaling booking created" }
      end
    end

    response.headers["Location"] = "/api/staff/v1/bookings/#{booking.id}"
    booking
  end

  # patches an existing booking with the changes provided
  @[AC::Route::PUT("/:id", body: :changes)]
  @[AC::Route::PATCH("/:id", body: :changes)]
  def update(
    changes : Booking,

    @[AC::Param::Info(description: "allows a client to override any limits imposed on bookings", example: "3")]
    limit_override : Int32? = nil
  ) : Booking
    changes.id = booking.id
    existing_booking = booking

    original_start = existing_booking.booking_start
    original_end = existing_booking.booking_end
    original_asset = existing_booking.asset_id

    {% for key in [:asset_id, :zones, :booking_start, :booking_end, :title, :description] %}
      begin
        existing_booking.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_present?
      rescue NilAssertionError
      end
    {% end %}

    extension_data = changes.extension_data unless changes.extension_data.nil?
    if extension_data
      booking_ext_data = existing_booking.extension_data
      data = booking_ext_data ? booking_ext_data.as_h : Hash(String, JSON::Any).new
      extension_data.not_nil!.as_h.each { |key, value| data[key] = value }
      existing_booking.change_extension_data(JSON::Any.new(data))
    end

    # reset the checked-in state if asset is different, or booking times are outside the originally approved window
    reset_state = existing_booking.asset_id_changed? && original_asset != existing_booking.asset_id
    if existing_booking.booking_start_changed? || existing_booking.booking_end_changed?
      raise Error::NotAllowed.new("editing booking times is allowed on parent bookings only.") unless existing_booking.parent?

      reset_state = true if existing_booking.booking_start < original_start || existing_booking.booking_end > original_end
    end

    if reset_state
      existing_booking.assign_attributes(
        booked_by_id: user_token.id,
        booked_by_email: PlaceOS::Model::Email.new(user.email),
        booked_by_name: user.name,
        checked_in: false,
        rejected: false,
        approved: false,
        last_changed: Time.utc.to_unix,
      )
    end

    # check there isn't a clashing booking
    clashing_bookings = check_clashing(existing_booking)
    raise Error::BookingConflict.new(clashing_bookings) if clashing_bookings.size > 0

    # check concurrent bookings don't exceed booking limits
    check_booking_limits(tenant, existing_booking, limit_override) if reset_state

    if existing_booking.valid?
      existing_attendees = existing_booking.attendees.try(&.map { |a| a.email.strip.downcase }) || [] of String
      # Check if attendees need updating
      update_attendees = !changes.req_attendees.nil?
      attendees = changes.req_attendees.try(&.map { |a| a.email.strip.downcase }) || existing_attendees
      attendees.uniq!

      if update_attendees
        existing_lookup = {} of String => Attendee
        existing = existing_booking.attendees.to_a
        existing.each { |a| existing_lookup[a.email.strip.downcase] = a }

        # Attendees that need to be deleted:
        remove_attendees = existing_attendees - attendees
        if !remove_attendees.empty?
          remove_attendees.each do |email|
            existing.select { |attend| attend.guest.try &.email == email }.each do |attend|
              attend.delete
            end
          end
        end

        # rejecting nil as we want to mark them as not attending where they might have otherwise been attending
        attending = changes.req_attendees.try(&.reject { |attendee| attendee.visit_expected.nil? })
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
                                      visit_expected: true,
                                      checked_in: false,
                                      tenant_id: tenant.id,
                                    )
                                    false
                                  end
            attend.update!(
              booking_id: existing_booking.id.not_nil!,
              guest_id: guest.id,
            )

            if !previously_visiting
              spawn do
                get_placeos_client.root.signal("staff/guest/attending", {
                  action:         :booking_updated,
                  id:             guest.id,
                  booking_id:     existing_booking.id,
                  resource_id:    existing_booking.asset_id,
                  event_summary:  existing_booking.title,
                  event_starting: existing_booking.booking_start,
                  attendee_name:  attendee.name,
                  attendee_email: attendee.email,
                  host:           existing_booking.user_email,
                  zones:          existing_booking.zones,
                })
              end
            end
          end
        end
      end
    end

    update_booking(existing_booking, reset_state ? "changed" : "metadata_changed")
  end

  # returns the booking requested
  @[AC::Route::GET("/:id")]
  def show : Booking
    booking
  end

  # marks the provided booking as deleted
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy(
    @[AC::Param::Info(description: "provided for use with analytics", example: "mobile")]
    utm_source : String? = nil
  ) : Nil
    booking.update!(
      deleted: true,
      deleted_at: Time.local.to_unix,
      utm_source: utm_source
    )

    spawn do
      begin
        get_placeos_client.root.signal("staff/booking/changed", {
          action:          :cancelled,
          id:              booking.id,
          booking_type:    booking.booking_type,
          booking_start:   booking.booking_start,
          booking_end:     booking.booking_end,
          timezone:        booking.timezone,
          resource_id:     booking.asset_id,
          user_id:         booking.user_id,
          user_email:      booking.user_email,
          user_name:       booking.user_name,
          zones:           booking.zones,
          process_state:   booking.process_state,
          last_changed:    booking.last_changed,
          approver_name:   user.name,
          approver_email:  user.email.downcase,
          title:           booking.title,
          checked_in:      booking.checked_in,
          description:     booking.description,
          extension_data:  booking.extension_data,
          booked_by_email: booking.booked_by_email,
          booked_by_name:  booking.booked_by_name,
        })
      rescue error
        Log.error(exception: error) { "while signaling booking cancelled" }
      end
    end
  end

  # approves a booking (if booking approval is required in an organisation)
  @[AC::Route::POST("/:id/approve")]
  def approve(
    @[AC::Param::Info(description: "provided for use with analytics", example: "mobile")]
    utm_source : String? = nil
  ) : Booking
    set_approver(booking, true)
    booking.approved_at = Time.utc.to_unix

    clashing_bookings = check_clashing(booking)
    raise Error::BookingConflict.new(clashing_bookings) if clashing_bookings.size > 0

    booking.utm_source = utm_source
    update_booking(booking, "approved")
  end

  # rejects a booking
  @[AC::Route::POST("/:id/reject")]
  def reject(
    @[AC::Param::Info(description: "provided for use with analytics", example: "mobile")]
    utm_source : String? = nil
  ) : Booking
    set_approver(booking, false)
    booking.rejected_at = Time.utc.to_unix
    booking.utm_source = utm_source
    update_booking(booking, "rejected")
  end

  # indicates that a booking has commenced
  @[AC::Route::POST("/:id/check_in")]
  @[AC::Route::POST("/:id/checkin")]
  def check_in(
    @[AC::Param::Info(description: "the desired value of the booking checked-in flag", example: "false")]
    state : Bool = true,
    @[AC::Param::Info(description: "provided for use with analytics", example: "mobile")]
    utm_source : String? = nil
  ) : Booking
    booking.checked_in = state

    if booking.checked_in
      # check concurrent bookings don't exceed booking limits
      raise Error::NotAllowed.new("a checked out booking cannot be checked back in") if booking.booking_current_state.checked_out?

      time_now = Time.utc.to_unix

      # Can't checkin after the booking end time
      raise Error::NotAllowed.new("The booking has ended") if booking.booking_end <= time_now

      # Check if we can check into a booking early (on the same day)
      raise Error::NotAllowed.new("Can only check in an hour before the booking start") if (booking.booking_start - time_now) > 3600

      # Check if there are any booking between now and booking start time
      if booking.booking_start > time_now
        clashing_bookings = check_in_clashing(time_now, booking)
        raise Error::BookingConflict.new(clashing_bookings) if clashing_bookings.size > 0
      end

      booking.checked_in_at = Time.utc.to_unix
      attendees = booking.attendees.to_a
      guest_checkin(attendees.first.email, true) if attendees.size == 1
    else
      # don't allow double checkouts, but might as well return a success response
      return booking if booking.booking_current_state.checked_out?
      booking.checked_out_at = Time.utc.to_unix
    end

    booking.utm_source = utm_source
    update_booking(booking, "checked_in")
  end

  # the current state of a booking, if a custom state machine is being used
  @[AC::Route::POST("/:id/update_state")]
  def update_state(
    @[AC::Param::Info(description: "the user defined process state of the booking", example: "pending_approval")]
    state : String,
    @[AC::Param::Info(description: "provided for use with analytics", example: "mobile")]
    utm_source : String? = nil
  ) : Booking
    booking.process_state = state
    booking.utm_source = utm_source
    update_booking(booking, "process_state")
  end

  # returns a list of guests associated with a booking
  @[AC::Route::GET("/:id/guests")]
  def guest_list : Array(Guest)
    booking.attendees.to_a.map do |visitor|
      visitor.guest.not_nil!.for_booking_to_h(visitor, booking)
    end
  end

  # marks the standalone visitor as checked-in or checked-out based on the state param
  @[AC::Route::POST("/:id/guests/:guest_id/check_in")]
  @[AC::Route::POST("/:id/guests/:guest_id/checkin")]
  def guest_checkin(
    @[AC::Param::Info(name: "guest_id", description: "the email of the guest we want to checkin", example: "person@external.com")]
    guest_email : String,
    @[AC::Param::Info(name: "state", description: "the checkin state, defaults to `true`", example: "false")]
    checkin : Bool = true
  ) : Guest
    guest = Guest.by_tenant(tenant.id).find_by(email: guest_email.strip.downcase)
    attendee = Attendee.by_tenant(tenant.id).find_by(guest_id: guest.id, booking_id: booking.id)

    attendee.booking = booking
    attendee.guest = guest
    attendee.checked_in = checkin
    attendee.save!

    spawn do
      get_placeos_client.root.signal("staff/guest/checkin", {
        action:         :checkin,
        id:             guest.id,
        checkin:        checkin,
        booking_id:     booking.id,
        resource_id:    booking.asset_id,
        event_summary:  booking.title,
        event_starting: booking.booking_start,
        attendee_name:  guest.name,
        attendee_email: guest.email,
        host:           booking.user_email,
        zones:          booking.zones,
      })
    end

    guest.for_booking_to_h(attendee, booking.as_h(include_attendees: false))
  end

  # ============================================
  #              Helper Methods
  # ============================================

  private def check_clashing(new_booking)
    starting = new_booking.booking_start
    ending = new_booking.booking_end
    booking_type = new_booking.booking_type
    asset_id = new_booking.asset_id

    # gets all the clashing bookings
    query = Booking
      .by_tenant(tenant.id)
      .where(
        "booking_start < ? AND booking_end > ? AND booking_type = ? AND asset_id = ? AND rejected <> TRUE AND deleted <> TRUE AND checked_out_at IS NULL",
        ending, starting, booking_type, asset_id
      )
    query = query.where("id != ?", new_booking.id) unless new_booking.id.nil?
    query.to_a
  end

  private def check_in_clashing(time_now, booking)
    booking_type = booking.booking_type
    asset_id = booking.asset_id
    query = Booking
      .by_tenant(tenant.id)
      .where(
        "booking_start < ? AND booking_end > ? AND booking_type = ? AND asset_id = ? AND rejected <> TRUE AND deleted <> TRUE AND checked_out_at IS NULL",
        booking.booking_start, time_now, booking_type, asset_id
      )
    query.to_a
  end

  private def check_concurrent(new_booking)
    # check for concurrent bookings
    starting = new_booking.booking_start
    ending = new_booking.booking_end
    booking_type = new_booking.booking_type
    user_id = new_booking.user_id || new_booking.booked_by_id
    zones = new_booking.zones || [] of String

    query = Booking
      .by_tenant(tenant.id)
      .where(
        "booking_start < ? AND booking_end > ? AND booking_type = ? AND user_id = ? AND rejected = FALSE AND deleted <> TRUE",
        ending, starting, booking_type, user_id
      )
    query = query.where("id != ?", new_booking.id) unless new_booking.id.nil?
    # TODO: Change to use the PostgreSQL `&&` array operator in the query above. (https://www.postgresql.org/docs/9.1/functions-array.html)
    query.to_a.reject do |booking|
      if (b_zones = booking.zones) && zones
        (b_zones & zones).empty?
      end
    end
  end

  private def check_booking_limits(tenant, booking, limit_override = nil)
    # check concurrent bookings don't exceed booking limits
    if limit = limit_override
      concurrent_bookings = check_concurrent(booking).reject { |b| b.booking_current_state.checked_out? }
      raise Error::BookingLimit.new(limit.to_i, concurrent_bookings) if concurrent_bookings.size >= limit.to_i
    else
      if booking_limits = tenant.booking_limits.as_h?
        if limit = booking_limits[booking.booking_type]?
          concurrent_bookings = check_concurrent(booking).reject { |b| b.booking_current_state.checked_out? }
          raise Error::BookingLimit.new(limit.as_i, concurrent_bookings) if concurrent_bookings.size >= limit.as_i
        end
      end
    end
  end

  private def update_booking(booking, signal = "changed")
    booking.save! rescue raise Error::ModelValidation.new(booking.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating booking data")

    spawn do
      begin
        get_placeos_client.root.signal("staff/booking/changed", {
          action:          signal,
          id:              booking.id,
          booking_type:    booking.booking_type,
          booking_start:   booking.booking_start,
          booking_end:     booking.booking_end,
          timezone:        booking.timezone,
          resource_id:     booking.asset_id,
          user_id:         booking.user_id,
          user_email:      booking.user_email,
          user_name:       booking.user_name,
          zones:           booking.zones,
          process_state:   booking.process_state,
          last_changed:    booking.last_changed,
          approver_name:   booking.approver_name,
          approver_email:  booking.approver_email,
          title:           booking.title,
          checked_in:      booking.checked_in,
          description:     booking.description,
          extension_data:  booking.extension_data,
          booked_by_email: booking.booked_by_email,
          booked_by_name:  booking.booked_by_name,
        })
      rescue error
        Log.error(exception: error) { "while signaling booking #{signal}" }
      end
    end

    booking
  end

  private def set_approver(booking, approved : Bool)
    # In case of rejections reset approver related information
    booking.assign_attributes(
      approver_id: user_token.id,
      approver_email: user.email.downcase,
      approver_name: user.name,
      approved: approved,
      rejected: !approved,
    )
  end
end
