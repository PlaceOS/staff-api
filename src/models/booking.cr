class Booking
  include Clear::Model
  alias AsHNamedTuple = NamedTuple(id: Int64, booking_type: String, booking_start: Int64, booking_end: Int64, timezone: String | Nil, asset_id: String, user_id: String, user_email: String, user_name: String, zones: Array(String) | Nil, process_state: String | Nil, last_changed: Int64 | Nil, approved: Bool, approved_at: Int64 | Nil, rejected: Bool, rejected_at: Int64 | Nil, approver_id: String | Nil, approver_name: String | Nil, approver_email: String | Nil, title: String | Nil, checked_in: Bool, checked_in_at: Int64 | Nil, checked_out_at: Int64 | Nil, description: String | Nil, booked_by_email: String, booked_by_name: String, extension_data: JSON::Any)

  column id : Int64, primary: true, presence: false

  column user_id : String
  column user_email : String
  column user_name : String
  column asset_id : String
  column zones : Array(String)? # default in migration

  column booking_type : String
  column booking_start : Int64
  column booking_end : Int64
  column timezone : String?

  column title : String?
  column description : String?

  column checked_in : Bool, presence: false
  column checked_in_at : Int64?
  column checked_out_at : Int64?

  column rejected : Bool, presence: false
  column rejected_at : Int64?
  column approved : Bool, presence: false
  column approved_at : Int64?
  column approver_id : String?
  column approver_email : String?
  column approver_name : String?

  column booked_by_id : String
  column booked_by_email : String
  column booked_by_name : String

  # if we want to record the system that performed the bookings
  # (kiosk, mobile, swipe etc)
  column booked_from : String?

  # used to hold information relating to the state of the booking process
  column process_state : String?
  column last_changed : Int64?
  column created : Int64?

  column extension_data : JSON::Any, presence: false

  belongs_to tenant : Tenant
  has_many attendees : Attendee, foreign_key: "booking_id"

  before :create, :set_created

  before(:save) do |m|
    booking_model = m.as(Booking)

    booking_model.user_id = booking_model.booked_by_id if !booking_model.user_id_column.defined?
    booking_model.booked_by_email = booking_model.booked_by_email.downcase
    booking_model.user_email = booking_model.booked_by_email if !booking_model.user_email_column.defined?
    booking_model.user_name = booking_model.booked_by_name if !booking_model.user_name_column.defined?
    booking_model.approver_email = booking_model.approver_email.try(&.downcase) if booking_model.approver_email_column.defined?
  end

  def set_created
    self.last_changed = self.created = Time.utc.to_unix
  end

  scope :by_tenant do |tenant_id|
    where { var("bookings", "tenant_id") == tenant_id }
  end

  scope :by_user_id do |user_id|
    user_id ? where(user_id: user_id) : self
  end

  scope :by_user_email do |user_email|
    user_email ? where(user_email: user_email) : self
  end

  scope :by_user_or_email do |user_id_value, user_email_value, include_booked_by|
    # TODO:: interpolate these values properly
    booked_by = include_booked_by ? %( OR "booked_by_id" = '#{user_id_value}') : ""
    user_id_value = user_id_value.try &.gsub(/[\'\"\)\(\\\/\$\?\;\:\<\>\.\+\=\*\&\^\#\!\`\%\}\{\[\]]/, "")
    user_email_value = user_email_value.try &.gsub(/[\'\"\)\(\\\/\$\?\;\:\<\>\=\*\&\^\!\`\%\}\{\[\]]/, "")

    if user_id_value && user_email_value
      where(%(("user_id" = '#{user_id_value}' OR "user_email" = '#{user_email_value}'#{booked_by})))
    elsif user_id_value
      # Not sure how to do OR's in clear
      where(%(("user_id" = '#{user_id_value}'#{booked_by})))
      # where(user_id: user_id_value)
    elsif user_email_value
      booked_by = include_booked_by ? %( OR "booked_by_email" = '#{user_email_value}') : ""
      where(%(("user_email" = '#{user_email_value}'#{booked_by})))
      # where(user_email: user_email_value)
    else
      self
    end
  end

  scope :by_ext do |value|
    if value
      parse = value.delete &.in?('{', '}')
      array = parse.split(",")
      array.each do |entry|
        split_entry = entry.split(":")
        where { extension_data.jsonb(split_entry[0]) == split_entry[1] }
      end
    else
      self
    end
  end

  scope :booking_state do |state|
    state ? where(process_state: state) : self
  end

  scope :created_before do |time|
    time ? where { last_changed < time.not_nil!.to_i64 } : self
  end

  scope :created_after do |time|
    time ? where { last_changed > time.not_nil!.to_i64 } : self
  end

  scope :booked_between do |tenant_id, period_start, period_end|
    by_tenant(tenant_id)
      .inner_join("attendees") { var("bookings", "id") == var("attendees", "booking_id") }
      .where("bookings.booking_start >= :period_start AND bookings.booking_end <= :period_end", period_start: period_start, period_end: period_end)
  end

  scope :is_approved do |value|
    if value
      check = value == "true"
      where { approved == check }
    else
      self
    end
  end

  scope :is_rejected do |value|
    if value
      check = value == "true"
      where { rejected == check }
    else
      self
    end
  end

  scope :is_checked_in do |value|
    if value
      check = value == "true"
      where { checked_in == check }
    else
      self
    end
  end

  # Bookings have the zones in an array.
  #
  # In case of multiple zones as input,
  # we return all bookings that have
  # any of the input zones in their zones array
  scope :by_zones do |zones|
    return self if zones.empty?

    # https://www.postgresql.org/docs/9.1/arrays.html#ARRAYS-SEARCHING
    query = zones.join(" OR ") do |zone|
      zone = zone.gsub(/[\'\"\)\(\\\/\$\?\;\:\<\>\.\+\=\*\&\^\#\!\`\%\}\{\[\]]/, "")
      "( '#{zone}' = ANY (zones) )"
    end

    where("( #{query} )")
  end

  def as_h : AsHNamedTuple
    {
      id:              id,
      booking_type:    booking_type,
      booking_start:   booking_start,
      booking_end:     booking_end,
      timezone:        timezone,
      asset_id:        asset_id,
      user_id:         user_id,
      user_email:      user_email,
      user_name:       user_name,
      zones:           zones,
      process_state:   process_state,
      last_changed:    last_changed,
      approved:        approved,
      approved_at:     approved_at,
      rejected:        rejected,
      rejected_at:     rejected_at,
      approver_id:     approver_id,
      approver_name:   approver_name,
      approver_email:  approver_email,
      title:           title,
      checked_in:      checked_in,
      checked_in_at:   checked_in_at,
      checked_out_at:  checked_out_at,
      description:     description,
      booked_by_email: booked_by_email,
      booked_by_name:  booked_by_name,
      extension_data:  extension_data,
    }
  end
end

class StaffApi::BookingWithAttendees
  include JSON::Serializable
  include JSON::Serializable::Unmapped

  property booking_attendees : Array(PlaceCalendar::Event::Attendee) = [] of PlaceCalendar::Event::Attendee
end
