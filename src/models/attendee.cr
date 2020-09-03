class Attendee
  include Clear::Model

  column id : Int64, primary: true, presence: false

  column checked_in : Bool = false
  column visit_expected : Bool = true
  column guest_id : Int64

  belongs_to tenant : Tenant, foreign_key: "tenant_id"
  belongs_to event_metadata : EventMetadata, foreign_key: "event_id"
  belongs_to guest : Guest, foreign_key: "guest_id"

  scope :by_tenant do |tenant_id|
    where { var("attendees", "tenant_id") == tenant_id }
  end

  def email
    guest.email
  end

  def to_h
    {
      email: email,
      checked_in: checked_in,
      visit_expected: visit_expected
    }
  end
end
