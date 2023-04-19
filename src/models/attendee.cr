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

  delegate email, name, preferred_name, phone, organisation, notes, photo, to: guest

  before(:save) do |m|
    attendee_model = m.as(Booking)
    attendee_model.survey_trigger
  end

  def survey_trigger
    return unless checked_in.changed?
    state = checked_in ? TriggerType::VISITOR_CHECKEDIN : TriggerType::VISITOR_CHECKEDOUT

    query = Survey.query.select("id").where(trigger: state)

    if (zones = booking.zones) && !zones.empty?
      query = query.where { var("zone_id").in?(zones) & var("building_id").in?(zones) }
    end

    email = guest.email
    unless email.empty?
      surveys = query.to_a
      surveys.each do |survey|
        Survey::Invitation.create!(
          survey_id: survey.id,
          email: email,
        )
      end
    end
  end

  struct AttendeeResponse
    include JSON::Serializable
    include AutoInitialize

    @[JSON::Field(format: "email")]
    getter email : String
    getter name : String?
    getter preferred_name : String?
    getter phone : String?
    getter organisation : String?
    getter notes : String?
    getter photo : String?

    property checked_in : Bool?
    property visit_expected : Bool?
    property event : PlaceCalendar::Event? = nil
  end

  def to_h(is_parent_metadata : Bool?, meeting_details : PlaceCalendar::Event?)
    AttendeeResponse.new(
      email: email,
      name: name,
      preferred_name: preferred_name,
      phone: phone,
      organisation: organisation,
      notes: notes,
      photo: photo,
      checked_in: is_parent_metadata ? false : checked_in,
      visit_expected: visit_expected,
      event: meeting_details
    )
  end

  def to_resp
    AttendeeResponse.new(
      email: email,
      name: name,
      preferred_name: preferred_name,
      phone: phone,
      organisation: organisation,
      notes: notes,
      photo: photo,
      checked_in: checked_in,
      visit_expected: visit_expected,
    )
  end

  def for_booking?
    !booking_id.nil?
  end
end
