class Attendee
  include Clear::Model

  column id : Int64, primary: true, presence: false

  column checked_in : Bool = false
  column visit_expected : Bool = true
  column guest_id : String

  belongs_to event_metadata : EventMetadata, foreign_key: "event_id"

  def email
    guest_id
  end
end
