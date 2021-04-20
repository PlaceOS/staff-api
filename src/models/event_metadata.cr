class EventMetadata
  include Clear::Model

  self.table = "event_metadatas"

  column id : Int64, primary: true, presence: false

  column system_id : String
  column event_id : String
  column recurring_master_id : String?
  column ical_uid : String

  column host_email : String
  column resource_calendar : String
  column event_start : Int64
  column event_end : Int64

  column ext_data : JSON::Any?

  belongs_to tenant : Tenant
  has_many attendees : Attendee, foreign_key: "event_metadata_id", own_key: "event_id"

  scope :by_tenant do |tenant_id|
    where { var("event_metadatas", "tenant_id") == tenant_id }
  end

  def self.migrate_recurring_metadata(system_id : String, recurrance : PlaceCalendar::Event, parent_metadata : EventMetadata)
    metadata = EventMetadata.new

    Clear::SQL.transaction do
      metadata.update!({
        ext_data:            parent_metadata.ext_data,
        tenant_id:           parent_metadata.tenant_id,
        system_id:           system_id,
        event_id:            recurrance.id.not_nil!,
        recurring_master_id: recurrance.recurring_event_id,
        ical_uid:            recurrance.ical_uid.not_nil!,
        event_start:         recurrance.event_start.not_nil!.to_unix,
        event_end:           recurrance.event_end.not_nil!.to_unix,
        resource_calendar:   parent_metadata.resource_calendar,
        host_email:          parent_metadata.host_email,
      })

      parent_metadata.attendees.where { var("attendees", "visit_expected") }.each do |attendee|
        Attendee.create!({
          event_id:       metadata.id.not_nil!,
          guest_id:       attendee.guest_id,
          tenant_id:      attendee.tenant_id,
          visit_expected: true,
          checked_in:     false,
        })
      end
    end

    metadata
  end
end
