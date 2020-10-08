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

  def self.migrate_recurring_metadata(system_id : String, recurrance : PlaceCalendar::Event, parent_metadata : EventMetadata)
    Clear::SQL.transaction do
      metadata = EventMetadata.new
      metadata.ext_data = parent_metadata.ext_data
      metadata.tenant_id = parent_metadata.tenant_id
      metadata.system_id = system_id
      metadata.event_id = recurrance.id.not_nil!
      metadata.event_start = recurrance.event_start.not_nil!.to_unix
      metadata.event_end = recurrance.event_end.not_nil!.to_unix
      metadata.resource_calendar = parent_metadata.resource_calendar
      metadata.host_email = parent_metadata.host_email
      metadata.save!

      parent_metadata.attendees.each do |attendee|
        if attendee.visit_expected
          attend = Attendee.new
          attend.event_id = metadata.id.not_nil!
          attend.guest_id = attendee.guest_id
          attend.tenant_id = attendee.tenant_id
          attend.visit_expected = true
          attend.checked_in = false
          attend.save!
        end
      end
    end
  end
end
