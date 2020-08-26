class Events < Application
  base "/api/staff/v1/events"

  # TODO: Needs following params
  # https://placeoscalendar.docs.apiary.io/#reference/0/events/list-events-occuring
  def index
    render json: client.list_events(user_id: user.email)
  end

  def show
    event_id = route_params["id"]
    if user_cal = query_params["calendar"]?
      # Need to confirm the user can access this calendar
      found = get_user_calendars.reject { |cal| cal.id != user_cal }.first?
      head(:not_found) unless found

      # Grab the event details
      event = get_event(user.email, nil, event_id, user_cal)
      head(:not_found) unless event

      render json: event
    elsif system_id = query_params["system_id"]?
      # Need to grab the calendar associated with this system
      begin
        system = get_placeos_client.systems.fetch(system_id)
      rescue _ex : ::PlaceOS::Client::API::Error
        head(:not_found)
      end
      cal_id = system.email
      head(:not_found) unless cal_id

      event = get_event(user.email, system, event_id, cal_id)
      head(:not_found) unless event

      render json: event
    end

    head :bad_request
  end

  private def get_user_calendars
    client.list_calendars(user.email)
  end

  private def get_event(mailbox, system, event_id, calendar_id)
    event = client.get_event(mailbox, id: event_id, calendar_id: calendar_id)
    return unless event

    StaffApi::Event.compose(event.not_nil!, system)
  end
end
