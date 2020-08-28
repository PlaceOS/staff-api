class Attendee
  include Clear::Model

  column id : Int64, primary: true, presence: false

  column checked_in : Bool = false
  column visit_expected : Bool = true
  column guest_id : Int64

  belongs_to event_metadata : EventMetadata, foreign_key: "event_id"
  belongs_to guest : Guest, foreign_key: "guest_id"

  def email
    guest.email
  end
end
