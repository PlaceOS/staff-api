require "place_calendar"

# Augments PlaceCalendar::Event as required by StaffAPI
class StaffApi::Event
  # So we don't have to allocate array objects
  NOP_PLACE_CALENDAR_ATTENDEES = [] of PlaceCalendar::Event::Attendee

  def self.augment(event : PlaceCalendar::Event, calendar = nil, system = nil, metadata = nil, is_parent_metadata = false)
    visitors = {} of String => Attendee

    if event.status == "cancelled"
      if calendar && metadata && !metadata.cancelled && calendar.downcase.in?({metadata.resource_calendar.downcase, metadata.host_email.downcase})
        metadata.cancelled = true
        metadata.save
      end
      metadata = nil
    elsif staff_api_attendees = metadata.try(&.attendees)
      staff_api_attendees.not_nil!.each { |vis| visitors[vis.email] = vis }
    end

    # Grab the list of external visitors
    attendees = (event.attendees || NOP_PLACE_CALENDAR_ATTENDEES).map do |attendee|
      attendee.email = attendee.email.downcase

      if visitor = visitors[attendee.email]?
        attendee.checked_in = is_parent_metadata ? false : visitor.checked_in
        attendee.visit_expected = visitor.visit_expected
        attendee.extension_data = visitor.try(&.guest).try(&.extension_data) || JSON.parse("{}")
      end

      attendee
    end

    event_start = event.event_start.not_nil!.to_unix
    event_end = event.event_end.try &.to_unix

    # Ensure metadata is in sync
    if metadata && (event_start != metadata.event_start || (event_end && event_end != metadata.event_end))
      metadata.update(
        event_start: (start_time = event_start),
        event_end: (event_end ? event_end : (start_time + 24.hours.to_i)),
      )
    end

    event.calendar = calendar
    event.attendees = attendees
    event.system = system
    if meta_id = metadata.try(&.id)
      bookings = Booking.where(event_id: meta_id, deleted: false).join(:left, Attendee, :booking_id).join(:left, Guest, "guests.id = attendees.guest_id").to_a.tap &.each(&.render_event=(false)) unless is_parent_metadata
      event.linked_bookings = bookings
      event.extension_data = metadata.try(&.ext_data)
      event.setup_time = metadata.try(&.setup_time)
      event.breakdown_time = metadata.try(&.breakdown_time)
      event.setup_event_id = metadata.try(&.setup_event_id)
      event.breakdown_event_id = metadata.try(&.breakdown_event_id)
      event.permission = metadata.try(&.permission)
    end
    event.recurring_master_id = event.recurring_event_id

    event
  end
end

# Adding attributes needed by Staff API
class PlaceCalendar::Event
  class System
    include JSON::Serializable

    property id : String
  end

  # Needed so that json input without attachments array can be accepted
  property attachments : Array(Attachment) = [] of PlaceCalendar::Attachment

  property calendar : String?

  # This is the resource calendar, it will be moved to one of the attendees
  property system_id : String?
  property system : System? | PlaceOS::Client::API::Models::System?

  property extension_data : JSON::Any?
  property recurring_master_id : String?

  @[JSON::Field(ignore_deserialize: true)]
  property linked_bookings : Array(PlaceOS::Model::Booking)? = nil

  property setup_time : Int64? = nil
  property breakdown_time : Int64? = nil
  property setup_event_id : String? = nil
  property breakdown_event_id : String? = nil

  property permission : PlaceOS::Model::EventMetadata::Permission? = nil

  struct Attendee
    property checked_in : Bool?
    property visit_expected : Bool?
    property extension_data : JSON::Any? = JSON.parse("{}")
    property preferred_name : String?
    property phone : String?
    property organisation : String?
    property photo : String?
    property notes : String?
    property banned : Bool?
    property dangerous : Bool?
  end
end
