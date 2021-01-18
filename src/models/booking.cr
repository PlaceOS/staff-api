class Booking
  include Clear::Model

  column id : Int64, primary: true, presence: false

  column user_id : String
  column user_email : String
  column user_name : String
  column asset_id : String
  column zones : Array(String) = [] of String

  column booking_type : String
  column booking_start : Int64
  column booking_end : Int64
  column timezone : String?

  column title : String?
  column description : String?
  column checked_in : Bool = false

  column rejected : Bool = false
  column approved : Bool = false
  column approver_id : String?
  column approver_email : String?
  column approver_name : String?

  column booked_by_id : String
  column booked_by_email : String
  column booked_by_name : String

  # used to hold information relating to the state of the booking process
  column process_state : String?

  column ext_data : JSON::Any?

  belongs_to tenant : Tenant, foreign_key: "tenant_id"

  scope :by_tenant do |tenant_id|
    where { var("bookings", "tenant_id") == tenant_id }
  end

  scope :by_user_id do |user_id|
    user_id ? where { var("bookings", "user_id") == user_id } : self
  end

  scope :by_user_email do |user_email|
    user_email ? where { var("bookings", "user_email") == user_email } : self
  end

  scope :booking_state do |state|
    state ? where { var("bookings", "process_state") == state } : self
  end

  # Bookings have the zones in an array.
  #
  # In case of multiple zones as input,
  # we return all bookings that have
  # any of the input zones in their zones array
  scope :by_zones do |zones|
    return self if zones.empty?

    # https://www.postgresql.org/docs/9.1/arrays.html#ARRAYS-SEARCHING
    query = zones.map { |_zone| " ( ? = ANY (zones)) " }.join("OR")

    where("( #{query} )", zones)
  end

  # FIXME: Clear models seem to be having trouble when serializing
  # to json from render inside controller, hence this dance
  def as_json
    result = JSON.parse(self.to_json).as_h
    # FE only cares about extension_data not ext_data
    result.reject!("ext_data")
    result["extension_data"] = ext_data || JSON.parse("{}")
    result
  end
end
