require "place_calendar"

# Augments PlaceCalendar::Event as required by StaffAPI
class StaffApi::Event
  # So we don't have to allocate array objects
  NOP_PLACE_CALENDAR_ATTENDEES = [] of PlaceCalendar::Event::Attendee

  def self.compose(event : PlaceCalendar::Event, calendar = nil, system = nil, metadata = nil)
    visitors = {} of String => Attendee

    if event.status == "cancelled"
      metadata.try &.delete
      metadata = nil
    else
      staff_api_attendees = metadata.try(&.attendees)
      if staff_api_attendees
        staff_api_attendees.not_nil!.each { |vis| visitors[vis.email] = vis }
      end
    end

    # Grab the list of external visitors
    attendees = (event.attendees || NOP_PLACE_CALENDAR_ATTENDEES).map do |attendee|
      email = attendee.email.downcase
      result = {
        name:            attendee.name,
        email:           email,
        response_status: attendee.response_status,
        organizer:       attendee.organizer,
        resource:        attendee.resource,
      }

      if visitor = visitors[email]?
        result = result.merge({checked_in:     visitor.checked_in,
                               visit_expected: visitor.visit_expected,
        })
      end

      result
    end

    event_start = event.event_start.not_nil!.to_unix
    event_end = event.event_end.try &.to_unix

    # Ensure metadata is in sync
    if metadata && (event_start != metadata.event_start || (event_end && event_end != metadata.event_end))
      metadata.event_start = start_time = event_start
      metadata.event_end = event_end ? event_end : (start_time + 24.hours.to_i)
      metadata.save
    end

    {
      id:             event.id,
      calendar:       calendar,
      status:         event.status,
      title:          event.title,
      body:           event.body,
      location:       event.location,
      host:           event.host,
      creator:        event.creator,
      private:        event.private?,
      event_start:    event_start,
      event_end:      event_end,
      timezone:       event.timezone,
      all_day:        event.all_day?,
      attendees:      attendees,
      recurring:      event.recurring,
      recurrence:     event.recurrence,
      attachments:    event.attachments,
      system:         system,
      extension_data: metadata.try(&.ext_data) || {} of Nil => Nil,
    }
  end
end
