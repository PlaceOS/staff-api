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
  column banned : Bool = false
  column dangerous : Bool = false
  column searchable : String?
  column ext_data : JSON::Any?

  has_many attendees : Attendee, foreign_key: "guest_id"

  def validate
    validate_email_uniqueness
  end

  private def validate_email_uniqueness
    if (!persisted? && Guest.query.find { raw("email = '#{self.email}'") }) || (persisted? && Guest.query.find { raw("email = '#{self.email}'") & raw("id != '#{self.id}'") })
      add_error("email", "duplicate error. A guest with this email already exists")
    end
  end
end
