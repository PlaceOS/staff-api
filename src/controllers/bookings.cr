# Bookings of desks, car parking spaces, lockers, visitors and other assets, with approval, check-in/out and attendee (guest) management
class Bookings < Application
  base "/api/staff/v1/bookings"

  # =====================
  # Filters
  # =====================
  # SERIALIZABLE isolation closes the read-committed race where two concurrent
  # create/update requests for the same asset+time both pass the clash check
  # before either commits, producing duplicate active bookings. On a
  # serialization failure (40001) or deadlock (40P01) the whole action is
  # retried a few times with jittered backoff before giving up.
  SERIALIZE_RETRY_CODES = {"40001", "40P01"}

  @[AC::Route::Filter(:around_action, only: [:create, :update])]
  def wrap_in_transaction(&)
    attempt = 0
    loop do
      PgORM::Database.transaction do |tx|
        tx.connection.exec("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        yield
      end
      break
    rescue error : PQ::PQError
      # only transient serialization/deadlock failures are safe to retry;
      # anything else (validation, conflict, etc.) must propagate immediately
      raise error unless SERIALIZE_RETRY_CODES.includes?(error.field_message(:code))
      attempt += 1
      raise error if attempt >= 3

      Log.info { "retrying serialised booking transaction (attempt #{attempt}): #{error.message}" }
      sleep((100 + rand(400)).milliseconds)
    end
  end

  # Skip actions that requres login
  # If a user is logged in then they will be run as part of
  # #set_tenant_from_domain
  skip_action :determine_tenant_from_domain, only: [:index, :add_attendee, :booked]
  skip_action :check_jwt_scope, only: [:index, :add_attendee, :booked]

  # Set the tenant based on the domain
  # This allows unauthenticated requests through
  # (for public bookings, further checks are done later)
  @[AC::Route::Filter(:before_action, only: [:index, :add_attendee, :booked])]
  private def set_tenant_from_domain
    if auth_token_present?
      check_jwt_scope
      determine_tenant_from_domain
    else
      domain = request.hostname.as?(String)
      raise Error::BadRequest.new("missing domain header") unless domain
      @tenant = Tenant.find_by?(domain: domain)
      raise Error::NotFound.new("could not find tenant with domain: #{domain}") unless tenant
    end
  end

  @[AC::Route::Filter(:before_action, except: [:index, :create, :booked, :clashing_assets])]
  private def find_booking(
    id : Int64,
    @[AC::Param::Info(description: "the occurrence of a recurring booking to act on, the instance id (the occurrence start time as a unix epoch in seconds) as returned in the booking `instance` field. Omit to act on the booking or whole series", example: "1661725146")]
    instance : Int64? = nil,
  )
    @booking = booking = Booking
      .by_tenant(tenant.id)
      .where(id: id)
      .join(:left, Attendee, :booking_id)
      .join(:left, Guest, "guests.id = attendees.guest_id")
      .limit(1).to_a.first { raise Error::NotFound.new("could not find booking with id: #{id}") }

    if instance
      booking.instance = instance
      @booking = booking.as_instance.hydrate_booking(booking)
    end
  end

  @[AC::Route::Filter(:before_action, only: [:update, :update_alt, :destroy, :update_state, :update_induction, :patch_extdata, :check_in])]
  private def confirm_access
    return if is_support?
    if user = current_user
      return if booking && ({booking.user_id, booking.booked_by_id}.includes?(user.id) || (booking.user_email.to_s == user.email.downcase))
      return if check_access(user.groups, booking.zones || [] of String).can_manage?
      head :forbidden
    end
  end

  @[AC::Route::Filter(:before_action, only: [:add_attendee, :destroy_attendee])]
  private def confirm_access_for_add_attendee
    return if booking.permission.public?
    return if is_support?
    if user = current_user
      return if booking && ({booking.user_id, booking.booked_by_id}.includes?(user.id) || (booking.user_email.to_s == user.email.downcase))
      return if check_access(user.groups, booking.zones || [] of String).can_manage?
      return if booking.permission.open? && (authority = user.authority) && (booking_tenant = booking.tenant) && (authority.domain == booking_tenant.domain)
      head :forbidden
    end
  end

  @[AC::Route::Filter(:before_action, only: [:approve, :reject, :check_in, :guest_checkin, :add_attendee, :destroy_attendee])]
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

  # Lists bookings overlapping a time period, with recurring bookings expanded into their individual occurrences.
  # `type` is required unless event_id or ical_uid is provided, which instead returns the bookings linked to that calendar event.
  # With no `user`, `email` or `zones` the signed in user's own bookings are returned; with `zones` every user's bookings in those zones are returned.
  # Deleted, checked out bookings are excluded by default. Use `booked` instead if you only need the ids of assets in use.
  # Unauthenticated requests are allowed (tenant resolved from the domain) and only return PUBLIC bookings.
  # Paginated: follow the `Link` response header (rel="next") to fetch the next page.
  @[AC::Route::GET("/", execution_context: "bookings")]
  def index(
    @[AC::Param::Info(name: "period_start", description: "start of the period to search, unix epoch in seconds. Defaults to now", example: "1661725146")]
    starting : Int64 = Time.utc.to_unix,
    @[AC::Param::Info(name: "period_end", description: "end of the period to search, unix epoch in seconds. Defaults to one hour from now", example: "1661743123")]
    ending : Int64 = 1.hours.from_now.to_unix,
    @[AC::Param::Info(name: "type", description: "the booking type to search, such as desk, parking, locker, visitor or group-event. Required unless event_id or ical_uid is provided", example: "desk")]
    booking_type : String? = nil,
    @[AC::Param::Info(description: "when true, deleted and non-deleted bookings are returned (overrides `deleted`)", example: "true")]
    include_deleted : Bool = false,
    @[AC::Param::Info(name: "deleted", description: "when true, only deleted bookings are returned. Ignored if `include_deleted=true`", example: "true")]
    deleted_flag : Bool = false,
    @[AC::Param::Info(description: "when true, checked out and not checked out bookings are returned (overrides `checked_out`)", example: "true")]
    include_checked_out : Bool = false,
    @[AC::Param::Info(name: "checked_out", description: "when true, only checked out bookings are returned. Ignored if `include_checked_out=true`", example: "true")]
    checked_out_flag : Bool = false,
    @[AC::Param::Info(description: "only include bookings in any of these zones (e.g. a building or level), comma separated zone ids. When provided, bookings of all users in the zones are returned unless `user` or `email` is also set", example: "zone-123,zone-456")]
    zones : String? = nil,
    @[AC::Param::Info(name: "email", description: "only include bookings owned by the user with this email. If none of `user`, `email` or `zones` is set the signed in user's bookings are returned", example: "user@org.com")]
    user_email : String? = nil,
    @[AC::Param::Info(name: "user", description: "only include bookings owned by this user id, use `current` for the signed in user", example: "user-1234")]
    user_id : String? = nil,
    @[AC::Param::Info(description: "when `email` or `user` is set (or defaulted to the signed in user), also include bookings that user made on behalf of others", example: "true")]
    include_booked_by : Bool? = nil,

    @[AC::Param::Info(description: "true only includes checked in bookings, false only includes bookings that have been checked out", example: "true")]
    checked_in : Bool? = nil,
    @[AC::Param::Info(description: "only include bookings last changed before this time, unix epoch in seconds", example: "1661743123")]
    created_before : Int64? = nil,
    @[AC::Param::Info(description: "only include bookings last changed after this time, unix epoch in seconds", example: "1661743123")]
    created_after : Int64? = nil,
    @[AC::Param::Info(description: "true only includes approved bookings, false only includes bookings that are not approved", example: "true")]
    approved : Bool? = nil,
    @[AC::Param::Info(description: "true only includes rejected bookings, false excludes them. Defaults to including both", example: "false")]
    rejected : Bool? = nil,
    @[AC::Param::Info(description: "only include bookings whose extension data contains all of these key/value pairs, as a JSON object", example: %({"entry1":"value to match","entry2":1234}))]
    extension_data : String? = nil,
    @[AC::Param::Info(description: "only include bookings in this process state, a user defined value (see update_state)", example: "pending-approval")]
    state : String? = nil,
    @[AC::Param::Info(description: "only include bookings belonging to this department, a user defined value", example: "accounting")]
    department : String? = nil,

    @[AC::Param::Info(description: "return the bookings linked to this calendar event id (e.g. an Office365 or Google event id). When set, `type` is optional and the period, zone and user filters are ignored", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String? = nil,
    @[AC::Param::Info(description: "return the bookings linked to the calendar event with this iCal UID. When set, `type` is optional and the period, zone and user filters are ignored", example: "19rh93h5t893h5v@calendar.iCloud.com")]
    ical_uid : String? = nil,
    @[AC::Param::Info(description: "the maximum number of bookings to return, defaults to 100", example: "100")]
    limit : Int32 = 100,
    @[AC::Param::Info(description: "the number of bookings to skip, used for pagination (take the next value from the `Link` header)", example: "0")]
    offset : Int32 = 0,
    @[AC::Param::Info(description: "position within the expanded recurring bookings, used for pagination (take the next value from the `Link` header)", example: "0")]
    recurrence : Int32 = 0,
    @[AC::Param::Info(description: "only include bookings with this permission level: PRIVATE, OPEN or PUBLIC. Ignored for unauthenticated requests, which only see PUBLIC bookings", example: "PUBLIC")]
    permission : String? = nil,
    @[AC::Param::Info(description: "internal use, a path suffix appended to the pagination `Link` header URL", example: "booked")]
    link_ext : String? = nil,
    @[AC::Param::Info(description: "when true, linked (child) bookings in the results include their parent booking", example: "true")]
    include_parent_bookings : Bool? = nil,
  ) : Array(Booking)
    query = Booking.by_tenant(tenant.id)

    # restrict query to public bookings if the user is unauthenticated
    query = query.where(permission: Booking::Permission::PUBLIC.to_s) unless auth_token_present?
    query = query.where(permission: permission) if !permission.nil? && auth_token_present?

    event_ids = [event_id.presence, ical_uid.presence].compact

    if event_ids.empty?
      raise AC::Route::Param::MissingError.new("missing required parameter 'type'", "type", "String") unless booking_type.presence

      series_not_deleted = include_deleted ? "" : " AND deleted_at IS NULL"
      query = query.where(
        %{(((recurrence_end > ? OR recurrence_end IS NULL) AND recurrence_type <> 'NONE' AND "booking_start" < ? AND rejected_at IS NULL#{series_not_deleted}) OR ("booking_start" < ? AND "booking_end" > ?))},
        starting, ending, ending, starting
      )

      zones = Set.new((zones || "").split(',').map(&.strip).reject(&.empty?)).to_a
      query = query.by_zones(zones) unless zones.empty?

      # We want to do a special current user query if no user details are provided
      # but only if we are not looking for public bookings
      if auth_token_present?
        if user_id == "current" || (user_id.nil? && zones.empty? && user_email.nil?)
          user_id = user_token.id
          user_email = user.email
        end

        # we want to query group-event bookings that the user can join
        # if zones are provided.
        if booking_type == "group-event" && !zones.empty?
          query = query.by_user_or_email(user_id, user_email, include_booked_by, include_open_permission: true, include_public_permission: true)
        else
          query = query.by_user_or_email(user_id, user_email, include_booked_by)
        end
      end
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

    query = query.where(deleted: deleted_flag) unless include_deleted

    unless include_checked_out
      # query = checked_out_flag ? query.where("checked_out_at != ?", nil) : query.where(checked_out_at: nil)
      query = checked_out_flag ? query.where("(bookings.checked_out_at IS NOT NULL OR bookings.checked_out_at != ?)", nil) : query.where("(bookings.checked_out_at IS NULL OR bookings.checked_out_at = ?)", nil)
    end

    total = query.count
    query = query.join(:left, Attendee, :booking_id).join(:left, Guest, "guests.id = attendees.guest_id") if auth_token_present?

    # rows that are returned as-is (standard bookings and rejected recurring parents,
    # plus deleted ones unless `include_deleted`, see `Booking#recurring_booking?`) must
    # sort before the recurring bookings that get expanded into instances: the next page
    # offset is `offset + rows consumed` which is only correct when the consumed rows are
    # a prefix of this page. This expression must match `recurring_booking?(include_deleted)`.
    expanded_series = include_deleted ? "bookings.recurrence_type <> 'NONE' AND NOT bookings.rejected" : "bookings.recurrence_type <> 'NONE' AND NOT bookings.deleted AND NOT bookings.rejected"
    query = query.order("(#{expanded_series})", :created)
      .offset(offset)
      .limit(limit)

    result = query.to_a
    num_unexpanded = result.count { |booking| !booking.recurring_booking?(include_deleted) }

    result = Booking.hydrate_parents(result) if include_parent_bookings && !result.empty?

    if starting && ending && num_unexpanded < result.size
      details = Booking.expand_bookings!(Time.unix(starting), Time.unix(ending), result, limit, recurrence, include_checked_out ? nil : checked_out_flag, include_deleted)

      # Set link
      range_end = offset + num_unexpanded + details.complete
      if range_end < total
        params["offset"] = range_end.to_s
        params["limit"] = limit.to_s
        params["recurrence"] = details.next_idx.to_s
        response.headers["Link"] = %(<#{base_route}/#{link_ext}?#{params}>; rel="next")
      end
    else
      range_end = result.size + offset
      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "bookings #{offset}-#{range_end - 1}/#{total}"

      # Set link
      if range_end < total
        params["offset"] = range_end.to_s
        params["limit"] = limit.to_s
        # no partially expanded recurring booking on this page, so nothing to skip on the next
        params.delete("recurrence") if params.has_key?("recurrence")
        response.headers["Link"] = %(<#{base_route}/#{link_ext}?#{params}>; rel="next")
      end
    end

    result
  end

  # Lists the unique ids of assets (desks, parking spaces, etc) booked during a time period, e.g. to find which assets are unavailable.
  # Accepts the same filters as listing bookings; `type` is required unless event_id or ical_uid is provided.
  # Deleted, rejected and checked out bookings are ignored. Unauthenticated requests only consider PUBLIC bookings.
  # Use `clashing-assets` to check specific assets against a proposed booking time instead.
  @[AC::Route::GET("/booked")]
  def booked(
    @[AC::Param::Info(name: "period_start", description: "start of the period to search, unix epoch in seconds. Defaults to now", example: "1661725146")]
    starting : Int64 = Time.utc.to_unix,
    @[AC::Param::Info(name: "period_end", description: "end of the period to search, unix epoch in seconds. Defaults to one hour from now", example: "1661743123")]
    ending : Int64 = 1.hours.from_now.to_unix,
    @[AC::Param::Info(name: "type", description: "the booking type to search, such as desk, parking, locker, visitor or group-event. Required unless event_id or ical_uid is provided", example: "desk")]
    booking_type : String? = nil,
    @[AC::Param::Info(description: "only include bookings in any of these zones (e.g. a building or level), comma separated zone ids. When provided, bookings of all users in the zones are returned unless `user` or `email` is also set", example: "zone-123,zone-456")]
    zones : String? = nil,
    @[AC::Param::Info(name: "email", description: "only include bookings owned by the user with this email. If none of `user`, `email` or `zones` is set the signed in user's bookings are returned", example: "user@org.com")]
    user_email : String? = nil,
    @[AC::Param::Info(name: "user", description: "only include bookings owned by this user id, use `current` for the signed in user", example: "user-1234")]
    user_id : String? = nil,
    @[AC::Param::Info(description: "when `email` or `user` is set (or defaulted to the signed in user), also include bookings that user made on behalf of others", example: "true")]
    include_booked_by : Bool? = nil,

    @[AC::Param::Info(description: "true only includes checked in bookings, false only includes bookings that have been checked out", example: "true")]
    checked_in : Bool? = nil,
    @[AC::Param::Info(description: "only include bookings last changed before this time, unix epoch in seconds", example: "1661743123")]
    created_before : Int64? = nil,
    @[AC::Param::Info(description: "only include bookings last changed after this time, unix epoch in seconds", example: "1661743123")]
    created_after : Int64? = nil,
    @[AC::Param::Info(description: "true only includes approved bookings, false only includes bookings that are not approved", example: "true")]
    approved : Bool? = nil,
    @[AC::Param::Info(description: "only include bookings whose extension data contains all of these key/value pairs, as a JSON object", example: %({"entry1":"value to match","entry2":1234}))]
    extension_data : String? = nil,
    @[AC::Param::Info(description: "only include bookings in this process state, a user defined value (see update_state)", example: "pending-approval")]
    state : String? = nil,
    @[AC::Param::Info(description: "only include bookings belonging to this department, a user defined value", example: "accounting")]
    department : String? = nil,

    @[AC::Param::Info(description: "return the bookings linked to this calendar event id (e.g. an Office365 or Google event id). When set, `type` is optional and the period, zone and user filters are ignored", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String? = nil,
    @[AC::Param::Info(description: "return the bookings linked to the calendar event with this iCal UID. When set, `type` is optional and the period, zone and user filters are ignored", example: "19rh93h5t893h5v@calendar.iCloud.com")]
    ical_uid : String? = nil,
    @[AC::Param::Info(description: "the maximum number of bookings to inspect, defaults to 100000", example: "100000")]
    limit : Int32 = 100000,
    @[AC::Param::Info(description: "the number of bookings to skip, used for pagination (take the next value from the `Link` header)", example: "0")]
    offset : Int32 = 0,
    @[AC::Param::Info(description: "only include bookings with this permission level: PRIVATE, OPEN or PUBLIC. Ignored for unauthenticated requests, which only see PUBLIC bookings", example: "PUBLIC")]
    permission : String? = nil,
  ) : Array(String)
    result = index(starting: starting, ending: ending, booking_type: booking_type, deleted_flag: false, include_checked_out: false,
      checked_out_flag: false, zones: zones, user_email: user_email, user_id: user_id, include_booked_by: include_booked_by, checked_in: checked_in,
      created_before: created_before, created_after: created_after, approved: approved, rejected: false, extension_data: extension_data, state: state,
      department: department, event_id: event_id, ical_uid: ical_uid, limit: limit, offset: offset, permission: permission, link_ext: "booked")
    asset_ids = [] of String
    result.each { |b| asset_ids.concat(b.asset_ids) unless b.checked_out_at || b.deleted }
    asset_ids.uniq!
  end

  # Checks which assets are already booked for a proposed booking, without creating anything.
  # The body is a booking that requires booking_start, booking_end (unix epoch seconds) and booking_type.
  # Returns the ids of assets with a clashing booking; if asset_ids or asset_id is set only those assets are checked,
  # otherwise every asset of that booking_type with a clash is returned.
  # Set return_available (requires asset_ids) to get the free assets instead, or include_clash_time to get the clashing time ranges.
  @[AC::MCP(behaviour: :read_only)]
  @[AC::Route::POST("/clashing-assets", body: :booking)]
  def clashing_assets(
    booking : Booking,
    @[AC::Param::Info(description: "when true, return the assets from the booking's asset_ids that are NOT booked, so asset_ids must contain every candidate asset", example: "false")]
    return_available : Bool = false,
    @[AC::Param::Info(description: "when true, return objects with asset_id, booking_start and booking_end for each clash rather than plain asset ids. Cannot be combined with return_available", example: "false")]
    include_clash_time : Bool = false,
  ) : Array(String) | Array(NamedTuple(asset_id: String, booking_start: Int64, booking_end: Int64))
    unless booking.booking_start_present? &&
           booking.booking_end_present? &&
           booking.booking_type_present?
      raise Error::ModelValidation.new([{field: nil.as(String?), reason: "Missing one of booking_start, booking_end, booking_type"}], "error validating booking data")
    end

    # Validate that booking_end is after booking_start
    if booking.booking_end <= booking.booking_start
      raise Error::ModelValidation.new([{field: "booking_end".as(String?), reason: "booking_end must be after booking_start"}], "error validating booking data")
    end

    if return_available && !(booking.asset_ids_present? || booking.asset_id_present?)
      raise Error::ModelValidation.new([{field: nil.as(String?), reason: "Missing asset_ids or asset_id"}], "error validating booking data")
    end

    if return_available && include_clash_time
      raise AC::Route::Param::Error.new("include_clash_time and return_available cannot be used together")
    end

    # Add the tenant details
    booking.tenant_id = tenant.id.not_nil!

    ignore_assets = (booking.asset_ids_present? || booking.asset_id_present?) ? false : true
    if ignore_assets
      booking.asset_id = ""
      booking.asset_ids = [] of String
    end

    clashing_bookings = check_clashing(booking, ignore_assets: ignore_assets)

    if include_clash_time
      asset_ids = [] of NamedTuple(asset_id: String, booking_start: Int64, booking_end: Int64)

      clashing_bookings.each do |clashing_booking|
        clashing_booking.asset_ids.each do |asset_id|
          asset_ids << {asset_id: asset_id, booking_start: clashing_booking.booking_start, booking_end: clashing_booking.booking_end}
        end
      end

      asset_ids
    else
      asset_ids = [] of String

      clashing_bookings.each do |clashing_booking|
        asset_ids.concat(clashing_booking.asset_ids)
      end

      asset_ids = booking.asset_ids - asset_ids if return_available

      asset_ids.uniq!
    end
  end

  # Creates a booking of an asset (desk, parking space, locker, visitor, etc) for the signed in user or on behalf of another user.
  # The body requires booking_start, booking_end (unix epoch seconds), booking_type and asset_id or asset_ids; set user_email/user_id to book for someone else.
  # Any attendees in the body are created as guests (visitors) of the booking and a `staff/guest/attending` signal is sent for each, which typically triggers visitor invites.
  # Only admins, support or managers of the booking's zones may create a booking that is already approved or rejected (403 otherwise).
  # Fails with 409 if the asset is already booked for that time and 410 if the user's concurrent booking limit is reached.
  # Returns the created booking and publishes a `staff/booking/changed` signal.
  @[AC::Route::POST("/", body: :booking, status_code: HTTP::Status::CREATED)]
  def create(
    booking : Booking,

    @[AC::Param::Info(description: "the client or channel making the change, recorded for analytics", example: "mobile")]
    utm_source : String? = nil,
    @[AC::Param::Info(description: "the maximum number of concurrent bookings of this type the user may hold in the booking's zones, used instead of the tenant's configured booking limit", example: "3")]
    limit_override : Int32? = nil,

    @[AC::Param::Info(description: "link the booking to this calendar event id (e.g. an Office365 or Google event id). The event must already have staff-api metadata, otherwise 422 is returned", example: "AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe")]
    event_id : String? = nil,
    @[AC::Param::Info(description: "link the booking to the calendar event with this iCal UID. The event must already have staff-api metadata, otherwise 422 is returned", example: "19rh93h5t893h5v@calendar.iCloud.com")]
    ical_uid : String? = nil,
  ) : Booking
    unless booking.booking_start_present? &&
           booking.booking_end_present? &&
           booking.booking_type_present? &&
           (booking.asset_ids_present? || booking.asset_id_present?)
      raise Error::ModelValidation.new([{field: nil.as(String?), reason: "Missing one of booking_start, booking_end, booking_type or asset_ids"}], "error validating booking data")
    end

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

    # check there isn't a clashing booking. we own clash detection here, so the
    # subsequent save! does not need to repeat the (expensive) check.
    clashing_bookings = check_clashing(booking)
    raise Error::BookingConflict.new(clashing_bookings) if clashing_bookings.size > 0
    booking.skip_clash_check = true

    # clear history
    booking.history = [] of Booking::History

    # Add the user details
    booking.booked_by_id = user_token.id
    booking.booked_by_email = PlaceOS::Model::Email.new(user.email)
    booking.booked_by_name = user.name

    # only approvers can create a booking that is already approved or rejected
    apply_approval_state(booking, booking.approved, booking.rejected) if booking.approved || booking.rejected

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
                  existing_guest.organisation = attendee.organisation if existing_guest.organisation != attendee.organisation
                  existing_guest.phone = attendee.phone if existing_guest.phone != attendee.phone
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
          signal("staff/guest/attending", {
            action:         :booking_created,
            id:             guest.id,
            booking_id:     booking.id,
            resource_id:    booking.asset_id,
            resource_ids:   booking.asset_ids,
            event_title:    booking.title,
            event_summary:  booking.description.presence || booking.title,
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
        signal("staff/booking/changed", {
          action:          :create,
          id:              booking.id,
          booking_type:    booking.booking_type,
          booking_start:   booking.booking_start,
          booking_end:     booking.booking_end,
          timezone:        booking.timezone,
          resource_id:     booking.asset_id,
          resource_ids:    booking.asset_ids,
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

  # Updates a booking with the fields provided in the body, only fields present are changed.
  # Use the `/instance/:instance` routes to change a single occurrence of a recurring booking. Times cannot be changed on a linked (child) booking (405).
  # Moving to a different asset or outside the original time window resets the check-in and approval state and re-checks booking limits (410).
  # Changing the time, asset or recurrence re-checks for clashes (409). Changing approved/rejected requires admin, support or zone manager access (403).
  # Providing attendees replaces the attendee list, creating guests for new attendees. Changing user_email moves the booking to that user (404 if unknown) and signals `staff/booking/host_changed`.
  # Only the booking owner, the person who booked it, admins/support or zone managers may update it.
  @[AC::Route::PUT("/:id", body: :changes)]
  @[AC::Route::PATCH("/:id", body: :changes)]
  @[AC::Route::PUT("/:id/instance/:instance", body: :changes)]
  @[AC::Route::PATCH("/:id/instance/:instance", body: :changes)]
  def update(
    changes : Booking,

    @[AC::Param::Info(description: "the maximum number of concurrent bookings of this type the user may hold in the booking's zones, used instead of the tenant's configured booking limit", example: "3")]
    limit_override : Int32? = nil,
  ) : Booking
    changes.id = booking.id
    changes.instance = booking.instance
    existing_booking = booking

    original_host_email = existing_booking.user_email
    original_start = existing_booking.booking_start
    original_end = existing_booking.booking_end
    original_assets = existing_booking.asset_ids
    original_zones = existing_booking.zones.dup
    original_approved = existing_booking.approved
    original_rejected = existing_booking.rejected

    {% for key in [:asset_id, :asset_ids, :zones, :booking_start, :booking_end, :all_day, :title, :description, :images, :induction, :recurrence_end, :recurrence_interval, :recurrence_nth_of_month, :recurrence_days, :recurrence_type, :permission, :user_email] %}
      begin
        existing_booking.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_present?
      rescue NilAssertionError
      end
    {% end %}

    # When the host changes, resolve the new user's id and name from the user_email
    if existing_booking.user_email_changed?
      if new_user_email = existing_booking.user_email.presence
        new_user = client.get_user_by_email(new_user_email)
        raise Error::NotFound.new("user #{new_user_email} not found") unless new_user
        existing_booking.user_id = new_user.id.presence || new_user_email
        existing_booking.user_name = new_user.name.presence || new_user_email
      end
    end

    # Only persist extension data when the client explicitly sends it. The
    # attribute is non-nilable with a `{}` default, so an absent key still
    # deserialises to an empty hash. Without the `_present?` guard an asset-only
    # update would snapshot the series' extension data onto the occurrence and
    # stop it inheriting later parent changes.
    if changes.extension_data_present? && !(extension_data = changes.extension_data).raw.nil?
      extension_data = extension_data.as_h
      unless extension_data.empty?
        booking_ext_data = existing_booking.extension_data
        # On an instance `existing_booking` contains the effective extension data.
        # Duplicate it before merging so the complete snapshot is persisted without
        # mutating the parent booking's shared hash.
        data = booking_ext_data ? booking_ext_data.as_h.dup : Hash(String, JSON::Any).new
        extension_data.each { |key, value| data[key] = value }
        existing_booking.change_extension_data(JSON::Any.new(data))
      end
    end

    # reset the checked-in state if asset is different, or booking times are outside the originally approved window
    if existing_booking.asset_ids_changed? && original_assets != existing_booking.asset_ids
      original_asset = original_assets.first?
      reset_state = true if original_asset && !original_asset.starts_with?("unallocated")
    end

    if existing_booking.booking_start_changed? || existing_booking.booking_end_changed?
      raise Error::NotAllowed.new("editing booking times is allowed on parent bookings only.") unless existing_booking.parent?

      reset_state = true if existing_booking.booking_start < original_start || existing_booking.booking_end > original_end
    end

    # We should never change the booked_by fields so instead let's add a history entry instead
    if reset_state
      change_time = Time.utc.to_unix
      existing_booking.assign_attributes(
        checked_in: false,
        rejected: false,
        approved: false,
        last_changed: change_time,
      )
      existing_booking.history << Booking::History.new(state: :reserved, time: change_time, source: "updated by #{user.email}")
      existing_booking.history_will_change!
    end

    # approval state changes are restricted to approvers. compared against the
    # stored state so a client echoing back the current values is a no-op
    approved = changes.approved_present? ? changes.approved : original_approved
    rejected = changes.rejected_present? ? changes.rejected : original_rejected
    if approved != original_approved || rejected != original_rejected
      apply_approval_state(existing_booking, approved, rejected)
    end

    # only check for clashes when the booked slot itself changed (time, asset or
    # recurrence pattern). metadata-only edits (approve, check-in, title, ...)
    # can't introduce a clash, so skip the expensive check. when we do check, the
    # save! below need not repeat it.
    if existing_booking.slot_changed?
      clashing_bookings = check_clashing(existing_booking)
      raise Error::BookingConflict.new(clashing_bookings) if clashing_bookings.size > 0
    end
    existing_booking.skip_clash_check = true

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
                signal("staff/guest/attending", {
                  action:         :booking_updated,
                  id:             guest.id,
                  booking_id:     existing_booking.id,
                  resource_id:    existing_booking.asset_id,
                  resource_ids:   existing_booking.asset_ids,
                  event_title:    existing_booking.title,
                  event_summary:  booking.description.presence || existing_booking.title,
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

    result = update_booking(
      existing_booking,
      reset_state ? "changed" : "metadata_changed",
      previous_booking_start: original_start,
      previous_booking_end: original_end,
      previous_zones: original_zones,
    )

    if original_host_email.to_s.downcase != existing_booking.user_email.to_s.downcase
      spawn do
        begin
          signal("staff/booking/host_changed", {
            action:              :host_changed,
            booking_id:          existing_booking.id,
            resource_id:         existing_booking.asset_id,
            resource_ids:        existing_booking.asset_ids,
            event_title:         existing_booking.title,
            event_summary:       existing_booking.description.presence || existing_booking.title,
            event_starting:      existing_booking.booking_start,
            previous_host_email: original_host_email,
            new_host_email:      existing_booking.user_email,
            zones:               existing_booking.zones,
          })
        rescue error
          Log.error(exception: error) { "while signaling booking host changed" }
        end
      end
    end

    result
  end

  # Merges the provided keys into the booking's extension data (custom fields), leaving other keys untouched.
  # Use the `/:instance` route to update a single occurrence of a recurring booking.
  # A `staff/booking/changed` signal is only published when signal_changes is true.
  # Only the booking owner, the person who booked it, admins/support or zone managers may update it. Returns the updated booking.
  @[AC::Route::PATCH("/:id/ext_data", body: :changes)]
  @[AC::Route::PATCH("/:id/ext_data/:instance", body: :changes)]
  def patch_extdata(
    changes : Hash(String, JSON::Any),

    @[AC::Param::Info(description: "when true, publish a `staff/booking/changed` signal (action extdata_changed) so other services are notified, defaults to false", example: "true")]
    signal_changes : Bool = false,
  ) : Booking
    book = booking
    return book if changes.empty?

    # `book` contains the effective extension data for a recurrence instance.
    # Duplicate it before merging so an explicit instance update persists a
    # complete snapshot without mutating the parent booking's shared hash.
    ext_data = book.extension_data.as_h.dup
    changes.each { |key, value| ext_data[key] = value }
    book.change_extension_data(JSON::Any.new ext_data)

    if signal_changes
      update_booking(book, "extdata_changed")
    else
      book.save! rescue raise Error::ModelValidation.new(book.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating booking data")
    end

    book
  end

  # Returns a single booking by id, including its attendees.
  # Use the `/instance/:instance` route to get a specific occurrence of a recurring booking.
  @[AC::Route::GET("/:id")]
  @[AC::Route::GET("/:id/instance/:instance")]
  def show : Booking
    booking
  end

  # Cancels a booking by marking it as deleted (it remains visible with `include_deleted`).
  # Use the `/instance/:instance` route to cancel a single occurrence of a recurring booking; without it the whole booking or series is cancelled.
  # Only the booking owner, the person who booked it, admins/support or zone managers may cancel it.
  # Publishes a `staff/booking/changed` signal with action `cancelled`.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  @[AC::Route::DELETE("/:id/instance/:instance", status_code: HTTP::Status::ACCEPTED)]
  def destroy(
    @[AC::Param::Info(description: "the client or channel making the change, recorded for analytics", example: "mobile")]
    utm_source : String? = nil,
  ) : Nil
    booking_local = booking
    booking_local.deleted = true
    booking_local.deleted_at = Time.local.to_unix
    booking_local.utm_source = utm_source
    booking_local.save!

    spawn do
      begin
        signal("staff/booking/changed", {
          action:          :cancelled,
          id:              booking_local.id,
          instance:        booking_local.instance,
          booking_type:    booking_local.booking_type,
          booking_start:   booking_local.booking_start,
          booking_end:     booking_local.booking_end,
          timezone:        booking_local.timezone,
          resource_id:     booking_local.asset_id,
          resource_ids:    booking_local.asset_ids,
          user_id:         booking_local.user_id,
          user_email:      booking_local.user_email,
          user_name:       booking_local.user_name,
          zones:           booking_local.zones,
          process_state:   booking_local.process_state,
          last_changed:    booking_local.last_changed,
          approver_name:   user.name,
          approver_email:  user.email.downcase,
          title:           booking_local.title,
          checked_in:      booking_local.checked_in,
          description:     booking_local.description,
          extension_data:  booking_local.extension_data,
          booked_by_email: booking_local.booked_by_email,
          booked_by_name:  booking_local.booked_by_name,
        })
      rescue error
        Log.error(exception: error) { "while signaling booking cancelled" }
      end
    end
  end

  # Approves a booking that is pending approval, recording the current user as the approver.
  # Use the `/:instance` route to approve a single occurrence of a recurring booking.
  # Requires admin, support or manager access to one of the booking's zones (403). Fails with 409 if the booking now clashes with another, 405 if it was deleted.
  # Publishes a `staff/booking/changed` signal with action `approved` and returns the booking.
  @[AC::Route::POST("/:id/approve")]
  @[AC::Route::POST("/:id/approve/:instance")]
  def approve(
    @[AC::Param::Info(description: "the client or channel making the change, recorded for analytics", example: "mobile")]
    utm_source : String? = nil,
  ) : Booking
    booking.utm_source = utm_source
    set_approver(booking, true)

    clashing_bookings = check_clashing(booking)
    raise Error::BookingConflict.new(clashing_bookings) if clashing_bookings.size > 0

    update_booking(booking, "approved")
  end

  # Rejects (declines) a booking, recording the current user as the approver.
  # Use the `/:instance` route to reject a single occurrence of a recurring booking.
  # Requires admin, support or manager access to one of the booking's zones (403), 405 if the booking was deleted.
  # Publishes a `staff/booking/changed` signal with action `rejected` and returns the booking.
  @[AC::Route::POST("/:id/reject")]
  @[AC::Route::POST("/:id/reject/:instance")]
  def reject(
    @[AC::Param::Info(description: "the client or channel making the change, recorded for analytics", example: "mobile")]
    utm_source : String? = nil,
  ) : Booking
    booking.utm_source = utm_source
    set_approver(booking, false)
    update_booking(booking, "rejected")
  end

  # Checks a booking in (the user has arrived) or, with state=false, checks it out (releasing the asset).
  # Check in fails with 405 if the booking has ended, was already checked out, or is too far before its start (tenant early check-in window),
  # and 409 if another booking of the asset is still active before the start. A booking with a single attendee also checks that guest in.
  # Checking out also checks out any guests on site. Use the `/:instance` routes for a single occurrence of a recurring booking.
  # Only the booking owner, the person who booked it, admins/support or zone managers may call this. Publishes a `staff/booking/changed` signal.
  @[AC::Route::POST("/:id/check_in")]
  @[AC::Route::POST("/:id/checkin")]
  @[AC::Route::POST("/:id/check_in/:instance")]
  @[AC::Route::POST("/:id/checkin/:instance")]
  def check_in(
    @[AC::Param::Info(description: "true to check in, false to check out. Defaults to true", example: "false")]
    state : Bool = true,
    @[AC::Param::Info(description: "the client or channel making the change, recorded for analytics", example: "mobile")]
    utm_source : String? = nil,
  ) : Booking
    # NOTE:: resolve this *before* touching `checked_in`. Both guards below ask what
    # the booking was already doing, and a half applied mutation (`checked_in`
    # flipped while `checked_in_at` / `checked_out_at` still hold their old values)
    # matches no branch of the state machine -- it resolves to `Unknown` and logs an
    # error on every check in and check out. The answer is the same either way, so
    # this is purely about asking the question at a point where it is answerable.
    already_checked_out = booking.booking_current_state.checked_out?

    booking.checked_in = state

    if booking.checked_in
      # check concurrent bookings don't exceed booking limits
      raise Error::NotAllowed.new("a checked out booking cannot be checked back in") if already_checked_out

      time_now = Time.utc.to_unix

      # Can't checkin after the booking end time
      raise Error::NotAllowed.new("The booking has ended") if booking.booking_end <= time_now
      early_checkin = booking.tenant!.early_checkin
      # Check if we can check into a booking early (on the same day)
      raise Error::NotAllowed.new("Can only check in an #{early_checkin.seconds.total_hours} hour before the booking start") if (booking.booking_start - time_now) > early_checkin

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
      return booking if already_checked_out
      booking.checked_out_at = Time.utc.to_unix
    end

    booking.utm_source = utm_source
    update_booking(booking, "checked_in")
    check_out_guests unless booking.checked_in
    booking
  end

  # Sets the booking's process state, a free-form value used by custom workflows (e.g. pending_approval).
  # Use the `/:instance` route for a single occurrence of a recurring booking.
  # Only the booking owner, the person who booked it, admins/support or zone managers may call this.
  # Publishes a `staff/booking/changed` signal with action `process_state` and returns the booking.
  @[AC::Route::POST("/:id/update_state")]
  @[AC::Route::POST("/:id/update_state/:instance")]
  def update_state(
    @[AC::Param::Info(description: "the new user defined process state of the booking", example: "pending_approval")]
    state : String,
    @[AC::Param::Info(description: "the client or channel making the change, recorded for analytics", example: "mobile")]
    utm_source : String? = nil,
  ) : Booking
    booking.process_state = state
    booking.utm_source = utm_source
    update_booking(booking, "process_state")
  end

  # Sets the induction (site safety briefing) status of a booking, typically a visitor booking.
  # Accepting or declining publishes a `staff/guest/induction_accepted` or `staff/guest/induction_declined` signal for the booking's first guest.
  # Use the `/:instance` route for a single occurrence of a recurring booking.
  # Only the booking owner, the person who booked it, admins/support or zone managers may call this. Publishes `staff/booking/changed` and returns the booking.
  @[AC::Route::POST("/:id/update_induction")]
  @[AC::Route::POST("/:id/update_induction/:instance")]
  def update_induction(
    @[AC::Param::Info(description: "the induction status: tentative, accepted or declined", example: "accepted")]
    induction : PlaceOS::Model::Booking::Induction,
    @[AC::Param::Info(description: "the client or channel making the change, recorded for analytics", example: "mobile")]
    utm_source : String? = nil,
  ) : Booking
    if (induction.accepted? || induction.declined?) &&
       (guest = booking.attendees.to_a[0]?.try &.guest)
      action = if induction.accepted?
                 :induction_accepted
               else
                 :induction_declined
               end

      spawn do
        signal("staff/guest/#{action}", {
          action:         action,
          id:             guest.id,
          induction:      induction,
          booking_id:     booking.id,
          resource_id:    booking.asset_id,
          resource_ids:   booking.asset_ids,
          event_title:    booking.title,
          event_summary:  booking.description.presence || booking.title,
          event_starting: booking.booking_start,
          attendee_name:  guest.name,
          attendee_email: guest.email,
          host:           booking.user_email,
          zones:          booking.zones,
        })
      end
    end

    booking.induction = induction
    booking.utm_source = utm_source
    update_booking(booking, "induction")
  end

  # Lists the guests (visitors) attending a booking, including their check-in state for this booking.
  # Set include_linked to also include guests of linked (child) bookings, de-duplicated by email.
  @[AC::Route::GET("/:id/guests")]
  def guest_list(
    @[AC::Param::Info(description: "when true and this is a parent booking, also include guests from its linked (child) bookings. Defaults to false", example: "true")]
    include_linked : Bool = false,
  ) : Array(Guest)
    guests = booking.attendees.to_a.map do |visitor|
      visitor.guest.not_nil!.for_booking_to_h(visitor, booking)
    end

    if include_linked && booking.parent?
      Booking.where(parent_id: booking.id)
        .join(:left, Attendee, :booking_id)
        .join(:left, Guest, "guests.id = attendees.guest_id")
        .to_a.each do |child|
        child.attendees.to_a.each do |visitor|
          guests << visitor.guest.not_nil!.for_booking_to_h(visitor, child)
        end
      end

      # Deduplicate by email in case a guest appears on both the parent
      # and a child booking
      guests.uniq! { |guest| guest.email.downcase }
    end

    guests
  end

  # Checks a guest (visitor) of a booking in or, with state=false, out.
  # Checking in a guest also checks the booking in. Checking out the last guest on site checks the booking out if it has not ended.
  # Publishes a `staff/guest/checkin` signal. Returns 404 if the guest is not an attendee of the booking, 405 if the booking was deleted.
  @[AC::Route::POST("/:id/guests/:guest_id/check_in")]
  @[AC::Route::POST("/:id/guests/:guest_id/checkin")]
  def guest_checkin(
    @[AC::Param::Info(name: "guest_id", description: "the email address of the guest to check in or out", example: "person@external.com")]
    guest_email : String,
    @[AC::Param::Info(name: "state", description: "true to check the guest in, false to check them out. Defaults to true", example: "false")]
    checkin : Bool = true,
  ) : Guest
    guest = Guest.by_tenant(tenant.id).find_by(email: guest_email.strip.downcase)
    attendee = Attendee.by_tenant(tenant.id).find_by(guest_id: guest.id, booking_id: booking.id)

    attendee.booking = booking
    attendee.guest = guest
    attendee.checked_in = checkin
    attendee.save!

    # checking a guest in also checks the booking in (`Attendee#sync_booking_checkin`).
    # this is the reverse: once the last visitor on site leaves, the booking is
    # checked out so it stops occupying the rest of its slot. `Attendee` only records
    # `checked_in`, so a visitor yet to arrive does not keep the booking active, and
    # checking out a visitor who never arrived releases it too.
    # a booking that has already ended no longer blocks anything, and a
    # `checked_out_at` past `booking_end` would leave it in an Unknown state.
    if !checkin && booking.booking_end > Time.utc.to_unix &&
       !booking.booking_current_state.checked_out? &&
       !Attendee.by_tenant(tenant.id).where(booking_id: booking.id, checked_in: true).exists?
      booking.checked_in = false
      booking.checked_out_at = Time.utc.to_unix
      update_booking(booking, "checked_in")
    end

    signal_guest_checkin(guest, checkin)

    guest.for_booking_to_h(attendee, booking.as_h(include_attendees: false))
  end

  # Adds a single attendee (guest) to a booking without replacing the existing attendees, e.g. to join a group event.
  # Creates the guest if their email is new and publishes a `staff/guest/attending` signal. Returns 400 if they already attend, 405 if the booking was deleted.
  # Allowed unauthenticated for PUBLIC bookings; OPEN bookings allow any user of the tenant's domain;
  # otherwise only the booking owner, the person who booked it, admins/support or zone managers.
  @[AC::Route::POST("/:id/attendee", body: :attendee)]
  def add_attendee(
    attendee : PlaceCalendar::Event::Attendee,
  ) : Attendee
    email = attendee.email.strip.downcase

    # Check if attendee already exists in the booking to avoid duplicates
    existing_attendee = booking.attendees.find { |a| a.email == email }
    raise Error::BadRequest.new("Attendee already exists in this booking") if existing_attendee

    # Create or find the guest associated with the attendee
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

    # Create attendee
    attend = existing_attendee || Attendee.new

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
      booking_id: booking.id,
      guest_id: guest.id,
    )

    if !previously_visiting
      spawn do
        signal("staff/guest/attending", {
          action:         :booking_updated,
          id:             guest.id,
          booking_id:     booking.id,
          resource_id:    booking.asset_id,
          resource_ids:   booking.asset_ids,
          event_title:    booking.title,
          event_summary:  booking.description.presence || booking.title,
          event_starting: booking.booking_start,
          attendee_name:  attendee.name,
          attendee_email: attendee.email,
          host:           booking.user_email,
          zones:          booking.zones,
        })
      end
    end

    attend
  end

  # Removes an attendee from a booking by their email, e.g. to leave a group event.
  # The guest record, and their attendance of other bookings and events, is kept. Returns 400 if they are not an attendee, 405 if the booking was deleted.
  # Requires authentication. Allowed for any user on PUBLIC bookings, any user of the tenant's domain on OPEN bookings,
  # otherwise only the booking owner, the person who booked it, admins/support or zone managers.
  @[AC::Route::DELETE("/:id/attendee/:attendee_id", status_code: HTTP::Status::ACCEPTED)]
  def destroy_attendee(
    @[AC::Param::Info(name: "attendee_id", description: "the email address of the attendee to remove", example: "person@example.com")]
    attendee_email : String,
  ) : Nil
    email = attendee_email.strip.downcase

    attendee = booking.attendees.find { |a| a.email.strip.downcase == email }
    raise Error::BadRequest.new("Attendee not found in this booking") unless attendee

    # the guest is shared with their other visits, deleting it would cascade to those attendees
    attendee.delete
  end

  # ============================================
  #              Helper Methods
  # ============================================

  private def check_clashing(new_booking, ignore_assets : Bool = false)
    new_booking.clashing_bookings(ignore_assets: ignore_assets).reject! { |book| book.id == new_booking.id && (new_booking.instance.nil? || book.instance == new_booking.instance) }
  end

  private def check_in_clashing(time_now, booking)
    booking_type = booking.booking_type
    return [] of Booking if booking_type.downcase == "visitor"
    asset_ids = (booking.asset_ids + [booking.asset_id]).uniq

    query = Booking
      .by_tenant(tenant.id)
      .where(
        "booking_start < ? AND booking_end > ? AND booking_type = ? AND asset_ids && #{booking.format_list_for_postgres(asset_ids)} AND rejected <> TRUE AND deleted <> TRUE AND checked_out_at IS NULL",
        booking.booking_start, time_now, booking_type
      ).where("id != ?", booking.id)
    query.to_a
  end

  private def check_concurrent(new_booking)
    # check for concurrent bookings
    starting = new_booking.booking_start
    ending = new_booking.booking_end
    booking_type = new_booking.booking_type
    user_id = new_booking.user_id || new_booking.booked_by_id
    zones = new_booking.zones || [] of String
    # a booking with no zones can never share a zone, so no concurrent booking
    # applies to it (matches the previous in-memory intersection behaviour)
    return [] of Booking if zones.empty?

    query = Booking
      .by_tenant(tenant.id)
      .where(
        "booking_start < ? AND booking_end > ? AND booking_type = ? AND user_id = ? AND zones && #{new_booking.format_list_for_postgres(zones)} AND rejected = FALSE AND deleted <> TRUE",
        ending, starting, booking_type, user_id
      )
    query = query.where("id != ?", new_booking.id) unless new_booking.id.nil?
    query.to_a
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

  # visitors can't remain on site for a meeting the host has checked out of.
  # only visitors who arrived are checked out, a no-show has nothing to leave
  private def check_out_guests : Nil
    Attendee.by_tenant(tenant.id).where(booking_id: booking.id, checked_in: true).each do |attendee|
      guest = attendee.guest.not_nil!
      attendee.booking = booking
      attendee.guest = guest
      attendee.checked_in = false
      attendee.save!
      signal_guest_checkin(guest, false)
    end
  end

  private def signal_guest_checkin(guest : Guest, checkin : Bool) : Nil
    spawn do
      signal("staff/guest/checkin", {
        action:         :checkin,
        id:             guest.id,
        checkin:        checkin,
        booking_id:     booking.id,
        resource_id:    booking.asset_id,
        resource_ids:   booking.asset_ids,
        event_title:    booking.title,
        event_summary:  booking.description.presence || booking.title,
        event_starting: booking.booking_start,
        attendee_name:  guest.name,
        attendee_email: guest.email,
        host:           booking.user_email,
        zones:          booking.zones,
      })
    end
  end

  private def update_booking(
    booking,
    signal = "changed",
    previous_booking_start : Int64? = nil,
    previous_booking_end : Int64? = nil,
    previous_zones : Array(String)? = nil,
  )
    booking.save! rescue raise Error::ModelValidation.new(booking.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating booking data")

    spawn do
      begin
        signal("staff/booking/changed", {
          action:                 signal,
          id:                     booking.id,
          instance:               booking.instance,
          booking_type:           booking.booking_type,
          booking_start:          booking.booking_start,
          booking_end:            booking.booking_end,
          timezone:               booking.timezone,
          resource_id:            booking.asset_id,
          resource_ids:           booking.asset_ids,
          previous_booking_start: previous_booking_start,
          previous_booking_end:   previous_booking_end,
          previous_zones:         previous_zones,
          user_id:                booking.user_id,
          user_email:             booking.user_email,
          user_name:              booking.user_name,
          zones:                  booking.zones,
          process_state:          booking.process_state,
          last_changed:           booking.last_changed,
          approver_name:          booking.approver_name,
          approver_email:         booking.approver_email,
          title:                  booking.title,
          checked_in:             booking.checked_in,
          description:            booking.description,
          extension_data:         booking.extension_data,
          booked_by_email:        booking.booked_by_email,
          booked_by_name:         booking.booked_by_name,
          induction:              booking.induction,
        })
      rescue error
        Log.error(exception: error) { "while signaling booking #{signal}" }
      end
    end

    booking
  end

  # approval state can only be changed by admins, support or a manager of one
  # of the booking's zones
  private def check_approval_access(booking)
    return if is_support?
    return if check_access(current_user.groups, booking.zones).can_manage?
    raise Error::Forbidden.new("approval permissions required for zones: #{booking.zones.join(", ")}")
  end

  # marks the booking approved or rejected by the current user.
  # the caller is responsible for saving the booking
  private def set_approver(booking, approved : Bool)
    check_approval_access(booking)

    # In case of rejections reset approver related information
    booking.assign_attributes(
      approver_id: user_token.id,
      approver_email: user.email.downcase,
      approver_name: user.name,
    )

    if approved
      booking.approved = true
      booking.approved_at = Time.utc.to_unix
      booking.rejected = false
      booking.rejected_at = nil
    else
      booking.approved = false
      booking.approved_at = nil
      booking.rejected = true
      booking.rejected_at = Time.utc.to_unix
    end

    booking
  end

  # applies an approval state provided in a request body
  private def apply_approval_state(booking, approved : Bool, rejected : Bool)
    if rejected
      set_approver(booking, false)
    elsif approved
      set_approver(booking, true)
    else
      # back to pending approval
      check_approval_access(booking)
      booking.assign_attributes(
        approved: false,
        approved_at: nil,
        rejected: false,
        rejected_at: nil,
        approver_id: nil,
        approver_email: nil,
        approver_name: nil,
      )
    end
  end
end
