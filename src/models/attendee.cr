class Attendee
  include Clear::Model

  column id : Int64, primary: true, presence: false

  column checked_in : Bool
  column visit_expected : Bool
  column guest_id : Int64

  belongs_to tenant : Tenant
  belongs_to event_metadata : EventMetadata?, foreign_key: "event_id"
  belongs_to booking : Booking?, foreign_key: "booking_id"
  belongs_to guest : Guest

  scope :by_tenant do |tenant_id|
    where { var("attendees", "tenant_id") == tenant_id }
  end

  scope :by_bookings do |tenant_id, booking_ids|
    with_guest
      .by_tenant(tenant_id)
      .inner_join("bookings") { var("bookings", "id") == var("attendees", "booking_id") }
      .inner_join("guests") { var("guests", "id") == var("attendees", "guest_id") }
      .where { var("attendees", "booking_id").in?(booking_ids) }
  end

  def email
    guest.email
  end

  struct AttendeeResponse
    include JSON::Serializable
    include AutoInitialize

    @[JSON::Field(format: "email")]
    getter email : String
    property checked_in : Bool?
    property visit_expected : Bool?
    property event : PlaceCalendar::Event? = nil
  end

  def to_h(is_parent_metadata, meeting_details)
    AttendeeResponse.new(
      email:          email,
      checked_in:     is_parent_metadata ? false : checked_in,
      visit_expected: visit_expected,
      event:          meeting_details
    )
  end

  def for_booking?
    !booking_id.nil?
  end
end
