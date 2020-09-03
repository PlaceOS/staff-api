class EventMetadata
  include Clear::Model

  self.table = "event_metadatas"

  column id : Int64, primary: true, presence: false

  column system_id : String
  column event_id : String

  column host_email : String
  column resource_calendar : String
  column event_start : Int64
  column event_end : Int64

  column ext_data : JSON::Any?

  belongs_to tenant : Tenant, foreign_key: "tenant_id"
  has_many attendees : Attendee, foreign_key: "event_id"

  scope :by_tenant do |tenant_id|
    where { var("event_metadatas", "tenant_id") == tenant_id }
  end
end
