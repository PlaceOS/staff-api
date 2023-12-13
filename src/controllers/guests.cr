require "csv"

class Guests < Application
  base "/api/staff/v1/guests"

  # =====================
  # Filters
  # =====================

  # Skip scope check for relevant routes
  skip_action :check_jwt_scope, only: [:show, :update]

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_guest(
    @[AC::Param::Info(name: "id", description: "looks up a guest using either their id or email", example: "external@org.com")]
    guest_id : Int64 | String
  )
    @guest = case guest_id
             in String
               Guest.by_tenant(tenant.id).find_by(email: guest_id.downcase)
             in Int64
               Guest.by_tenant(tenant.id).find(guest_id)
             end
  end

  getter! guest : Guest

  # =====================
  # Request Queue
  # =====================

  # queue requests on a per-user basis
  @[AC::Route::Filter(:around_action, only: [:index, :meetings])]
  Application.add_request_queue

  # =====================
  # Routes
  # =====================

  # lists known guests (which can be queried) OR locates visitors via meeting start and end times (can be filtered by calendars, zone_ids and system_ids)
  @[AC::Route::GET("/", converters: {zones: ConvertStringArray})]
  def index(
    @[AC::Param::Info(name: "q", description: "space seperated search query for guests", example: "steve von")]
    search_query : String = "",
    @[AC::Param::Info(name: "period_start", description: "event period start as a unix epoch", example: "1661725146")]
    starting : Int64? = nil,
    @[AC::Param::Info(name: "period_end", description: "event period end as a unix epoch", example: "1661743123")]
    ending : Int64? = nil,
    @[AC::Param::Info(description: "[deprecated] a comma seperated list of calendar ids, recommend using `system_id` for resource calendars", example: "user@org.com,room2@resource.org.com")]
    calendars : String? = nil,
    @[AC::Param::Info(description: "[deprecated] a comma seperated list of zone ids used for events or bookings", example: "zone-123,zone-456")]
    zone_ids : String? = nil,
    @[AC::Param::Info(description: "[deprecated] a comma seperated list of event spaces", example: "sys-1234,sys-5678")]
    system_ids : String? = nil,
    @[AC::Param::Info(description: "a comma seperated list of zone ids for bookings", example: "zone-123,zone-456")]
    zones : Array(String)? = nil
  ) : Array(Guest)
    search_query = search_query.gsub(/[^\w\s\@\-\.\~\_\"]/, "").strip.downcase

    if starting && ending
      period_start = Time.unix(starting)
      period_end = Time.unix(ending)

      # Grab the bookings
      booking_lookup = {} of Int64 => Booking
      booking_ids = Set(Int64).new

      query = Booking.by_tenant(tenant.id)
      query = query.where(
        %("booking_start" < ? AND "booking_end" > ?),
        ending, starting
      )

      zones = Set.new(zones || [] of String).concat((zone_ids || "").split(',').map(&.strip).reject(&.empty?)).to_a
      query = query.by_zones(zones) unless zones.empty?

      query.order(created: :asc).each do |booking|
        booking_ids << booking.id.not_nil!
        booking_lookup[booking.id.not_nil!] = booking
      end

      # We want a subset of the calendars
      calendars = matching_calendar_ids(calendars, zone_ids, system_ids)
      return [] of Guest if calendars.empty? && booking_ids.empty?

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
      return [] of Guest if metadata_ids.empty? && booking_ids.empty?

      # Return the guests visiting today
      attendees = {} of String => Attendee

      sql = <<-SQL
        SELECT a.* FROM "attendees" a INNER JOIN "event_metadatas" m ON m.id = a.event_id
        INNER JOIN "guests" g ON g.id = a.guest_id
        WHERE a.tenant_id = $1
      SQL

      param_tmp = case client.client_id
                  when :office365
                    sql += " AND m.ical_uid IN (#{Guest.build_clause(ical_uids, 2)})"
                    ical_uids.to_a
                  else
                    sql += " AND m.event_id IN (#{Guest.build_clause(metadata_ids, 2)})"
                    metadata_ids.to_a
                  end

      # can't be any guests if there are no events
      if !param_tmp.empty?
        Attendee.find_all_by_sql(sql, tenant.id.not_nil!, args: param_tmp).each do |attend|
          attend.checked_in = false if attend.event_metadata.try &.event_id.try &.in?(metadata_recurring_ids)
          attendees[attend.guest.not_nil!.email] = attend
        end
      end

      if !booking_ids.empty?
        booking_attendees = Attendee.by_bookings(tenant.id, booking_ids.to_a)
        booking_attendees.each do |attend|
          attendees[attend.guest.not_nil!.email] = attend
        end
      end

      return [] of Guest if attendees.empty?

      guests = {} of String => Guest
      Guest
        .by_tenant(tenant.id)
        .where(email: attendees.keys)
        .each { |guest| guests[guest.not_nil!.email.not_nil!] = guest }

      attendees.compact_map do |email, visitor|
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
          attending_guest(visitor, guest, meeting_details: meeting_event).as(Guest)
        end
      end
    elsif search_query.empty?
      # Return the first 1500 guests
      Guest
        .by_tenant(tenant.id.not_nil!)
        .order(:name)
        .limit(1500).to_a
    else
      # Return guests based on the filter query
      csv = CSV.new(search_query, strip: true, separator: ' ')
      csv.next
      parts = csv.row.to_a

      sql_query = Guest.by_tenant(tenant.id)
      parts.each do |part|
        next if part.empty?
        sql_query = sql_query.where("searchable LIKE ?", "%#{part}%")
      end

      sql_query.order(:name).limit(1500).to_a
    end
  end

  # returns the details of a particular guest and if they are expected to attend in person today
  @[AC::Route::GET("/:id")]
  def show : Guest
    if user_token.guest_scope? && (guest.email != user_token.id)
      raise Error::Forbidden.new("guest #{user_token.id} attempting to edit #{guest.email}")
    end

    # find out if they are attending today
    attendee = guest.attending_today(tenant.id, get_timezone)
    !attendee.nil? && attendee.for_booking? ? guest.for_booking_to_h(attendee, attendee.booking.try(&.as_h)) : attending_guest(attendee, guest).as(Guest)
  end

  # patches a guest record with the changes provided
  @[AC::Route::PUT("/:id", body: :guest_req)]
  @[AC::Route::PATCH("/:id", body: :guest_req)]
  def update(guest_req : ::Guest) : Guest
    if user_token.guest_scope? && (guest.email != user_token.id)
      raise Error::Forbidden.new("guest #{user_token.id} attempting to edit #{guest.email}")
    end

    begin
      guest.patch(guest_req)
    rescue ex
      if ex.is_a?(PgORM::Error::RecordInvalid)
        raise Error::ModelValidation.new(guest.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating tenant data")
      else
        raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating tenant data")
      end
    end

    attendee = guest.attending_today(tenant.id, get_timezone)
    attending_guest(attendee, guest).as(Guest)
  end

  # creates a new guest record
  @[AC::Route::POST("/", body: :guest, status_code: HTTP::Status::CREATED)]
  def create(guest : Guest) : Guest
    guest.tenant_id = tenant.id

    begin
      guest.save!
    rescue ex
      if ex.is_a?(PgORM::Error::RecordInvalid)
        raise Error::ModelValidation.new(guest.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating tenant data")
      else
        raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating tenant data")
      end
    end

    attendee = guest.attending_today(tenant.id, get_timezone)
    attending_guest(attendee, guest).as(Guest)
  end

  # removes the guest record from the database
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    # TODO: Should we be allowing to delete guests that are associated with attendees?
    guest.delete
  end

  # returns the meetings that the provided guest is attending today (approximation based on internal records)
  @[AC::Route::GET("/:id/meetings")]
  def meetings(
    @[AC::Param::Info(description: "shoule we include past events they have visited", example: "true")]
    include_past : Bool = false,
    @[AC::Param::Info(description: "how many results to return", example: "10")]
    limit : Int32 = 10
  ) : Array(PlaceCalendar::Event)
    future_only = !include_past
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

    events
  end

  # returns the list of bookings a guest is expected to or has attended in person
  @[AC::Route::GET("/:id/bookings")]
  def bookings(
    @[AC::Param::Info(description: "shoule we include past bookings", example: "true")]
    include_past : Bool = false,
    @[AC::Param::Info(description: "how many results to return", example: "10")]
    limit : Int32 = 10
  ) : Array(Booking)
    if user_token.guest_scope? && (guest.email != user_token.id)
      raise Error::Forbidden.new("guest #{user_token.id} attempting to view bookings for #{guest.email}")
    end

    future_only = !include_past
    guest.bookings(future_only, limit).to_a
  end
end
