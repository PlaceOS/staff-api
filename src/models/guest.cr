class Guest
  include Clear::Model

  column id : Int64, primary: true, presence: false

  column email : String
  column name : String?
  column preferred_name : String?
  column phone : String?
  column organisation : String?
  column notes : String?
  column photo : String?
  column banned : Bool
  column dangerous : Bool
  column searchable : String?
  column extension_data : JSON::Any, presence: false

  belongs_to tenant : Tenant
  has_many attendees : Attendee, foreign_key: "guest_id"

  # Save searchable information
  before(:save) do |m|
    guest_model = m.as(Guest)
    guest_model.email = guest_model.email.downcase
    searchable_string = guest_model.email
    searchable_string += " #{guest_model.name}" if guest_model.name_column.defined?
    searchable_string += " #{guest_model.preferred_name}" if guest_model.preferred_name_column.defined?
    searchable_string += " #{guest_model.organisation}" if guest_model.organisation_column.defined?
    searchable_string += " #{guest_model.phone}" if guest_model.phone_column.defined?
    searchable_string += " #{guest_model.id}" if guest_model.id_column.defined?
    guest_model.searchable = searchable_string.downcase
  end

  scope :by_tenant do |tenant_id|
    where { var("guests", "tenant_id") == tenant_id }
  end

  def validate
    set_booleans
  end

  def to_h(visitor : Attendee?, is_parent_metadata, meeting_details)
    result = {
      checked_in:     is_parent_metadata ? false : visitor.try(&.checked_in) || false,
      visit_expected: visitor.try(&.visit_expected) || false,
    }
    result = result.merge(base_to_h)

    if meeting_details
      result = result.merge({event: meeting_details})
    end

    result
  end

  def for_booking_to_h(visitor : Attendee, booking_details)
    result = {
      checked_in:     visitor.checked_in,
      visit_expected: visitor.visit_expected,
    }
    result = result.merge(base_to_h)

    if booking_details
      result = result.merge({booking: booking_details})
    end

    result
  end

  def base_to_h
    {
      id:             id,
      email:          email,
      name:           name,
      preferred_name: preferred_name,
      phone:          phone,
      organisation:   organisation,
      notes:          notes,
      photo:          photo,
      banned:         banned,
      dangerous:      dangerous,
      extension_data: extension_data,
    }
  end

  def attending_today(tenant_id, timezone)
    now = Time.local(timezone)
    morning = now.at_beginning_of_day.to_unix
    tonight = now.at_end_of_day.to_unix

    # # TO FIX: Should run the following query and do a single query instead of doing two queries below
    # Attendee.query
    #   .by_tenant(tenant_id)
    #   .inner_join("event_metadatas") { var("event_metadatas", "id") == var("attendees", "event_id") }
    #   .where("guest_id = :guest_id AND event_metadatas.event_start >= :morning AND event_metadatas.event_end <= :tonight", guest_id: id, morning: morning, tonight: tonight)
    #   .first

    eventmetadatas = EventMetadata.query
      .inner_join("attendees") { var("event_metadatas", "id") == var("attendees", "event_id") }
      .where { var("attendees", "tenant_id") == tenant_id }
      .where("attendees.guest_id = :guest_id AND event_metadatas.event_start >= :morning AND event_metadatas.event_end <= :tonight", guest_id: id, morning: morning, tonight: tonight)
      .map(&.id).flatten # ameba:disable Performance/FlattenAfterMap

    bookings = Booking.query
      .inner_join("attendees") { var("bookings", "id") == var("attendees", "booking_id") }
      .where { var("attendees", "tenant_id") == tenant_id }
      .where("attendees.guest_id = :guest_id AND bookings.booking_start >= :morning AND bookings.booking_end <= :tonight", guest_id: id, morning: morning, tonight: tonight)
      .map(&.id).flatten # ameba:disable Performance/FlattenAfterMap

    Attendee.query.find { var("attendees", "event_id").in?(eventmetadatas) | var("attendees", "booking_id").in?(bookings) }
  end

  def events(future_only = true, limit = 10)
    if future_only
      EventMetadata.query
        .inner_join("attendees") { var("attendees", "event_id") == var("event_metadatas", "id") }
        .where("attendees.guest_id = :guest_id AND event_metadatas.event_end >= :now", guest_id: id, now: Time.utc.to_unix)
        .order_by(:event_start, :asc)
        .limit(limit)
    else
      EventMetadata.query
        .inner_join("attendees") { var("attendees", "event_id") == var("event_metadatas", "id") }
        .where("attendees.guest_id = :guest_id", guest_id: id)
        .order_by(:event_start, :asc)
        .limit(limit)
    end
  end

  def bookings(future_only = true, limit = 10)
    if future_only
      Booking.query
        .inner_join("attendees") { var("attendees", "booking_id") == var("bookings", "id") }
        .where("attendees.guest_id = :guest_id AND bookings.booking_end >= :now", guest_id: id, now: Time.utc.to_unix)
        .order_by(:booking_start, :asc)
        .limit(limit)
    else
      Booking.query
        .inner_join("attendees") { var("attendees", "booking_id") == var("bookings", "id") }
        .where("attendees.guest_id = :guest_id", guest_id: id)
        .order_by(:booking_start, :asc)
        .limit(limit)
    end
  end

  def attendee_for(event_id)
    Attendee.create!({
      event_id:       event_id,
      guest_id:       self.id,
      tenant_id:      self.tenant_id,
      checked_in:     false,
      visit_expected: true,
    })
  end

  private def set_booleans
    self.dangerous = false if !dangerous_column.defined?
    self.banned = false if !banned_column.defined?
  end
end
