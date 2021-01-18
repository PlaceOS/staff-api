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
  column banned : Bool
  column dangerous : Bool
  column searchable : String?
  column ext_data : JSON::Any?

  belongs_to tenant : Tenant
  has_many attendees : Attendee, foreign_key: "guest_id"

  # Save searchable information
  before(:save) do |m|
    guest_model = m.as(Guest)
    searchable_string = ""
    searchable_string += guest_model.name.to_s if guest_model.name_column.defined?
    searchable_string += " #{guest_model.preferred_name}" if guest_model.preferred_name_column.defined?
    searchable_string += " #{guest_model.organisation}" if guest_model.organisation_column.defined?
    searchable_string += " #{guest_model.id}" if guest_model.id_column.defined?
    guest_model.searchable = searchable_string.downcase
  end

  scope :by_tenant do |tenant_id|
    where { var("guests", "tenant_id") == tenant_id }
  end

  def validate
    validate_email_uniqueness
  end

  def to_h(visitor : Attendee?, is_parent_metadata, meeting_details)
    result = {
      email:          email,
      name:           name,
      preferred_name: preferred_name,
      phone:          phone,
      organisation:   organisation,
      notes:          notes,
      photo:          photo,
      banned:         banned,
      dangerous:      dangerous,
      extension_data: ext_data,
      checked_in:     is_parent_metadata ? false : visitor.try(&.checked_in) || false,
      visit_expected: visitor.try(&.visit_expected) || false,
    }

    if meeting_details
      result = result.merge({event: meeting_details})
    end

    result
  end

  def attending_today(tenant_id, timezone)
    now = Time.local(timezone)
    morning = now.at_beginning_of_day.to_unix
    tonight = now.at_end_of_day.to_unix

    Attendee.query
      .by_tenant(tenant_id)
      .inner_join("event_metadatas") { var("event_metadatas", "id") == var("attendees", "event_id") }
      .where("guest_id = :guest_id AND event_metadatas.event_start >= :morning AND event_metadatas.event_end <= :tonight", guest_id: id, morning: morning, tonight: tonight)
      .first
  end

  def events(future_only = true, limit = 10)
    if future_only
      EventMetadata.query
        .inner_join("attendees") { var("attendees", "event_id") == var("event_metadatas", "id") }
        .where("attendees.guest_id = :guest_id AND event_metadatas.event_end >= :now", guest_id: id, now: Time.utc.to_unix)
        .order_by(:event_start, :asc)
        .limit(limit)
    else
      EventMetadata.query
        .inner_join("attendees") { var("attendees", "event_id") == var("event_metadatas", "id") }
        .where("attendees.guest_id = :guest_id", guest_id: id)
        .order_by(:event_start, :asc)
        .limit(limit)
    end
  end

  def attendee_for(event_id)
    attend = Attendee.new
    attend.event_id = event_id
    attend.guest_id = self.id
    attend.tenant_id = self.tenant_id
    attend.checked_in = false
    attend.visit_expected = true
    attend.save!
    attend
  end

  # TODO: Update to take tenant_id into account
  private def validate_email_uniqueness
    if (!persisted? && email_column.defined? && Guest.query.find { raw("email = '#{self.email}'") }) || (persisted? && Guest.query.find { raw("email = '#{self.email}'") & raw("id != '#{self.id}'") })
      add_error("email", "duplicate error. A guest with this email already exists")
    end
  end
end
