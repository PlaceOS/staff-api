class Staff < Application
  base "/api/staff/v1/people"

  def index
    query = params["q"]?
    render json: client.list_users(query)
  end

  def show
    id = params["id"]
    # NOTE:: works for ids and email addresses
    render json: client.get_user_by_email(id)
  end

  get("/:id/groups", :groups) do
    id = params["id"]
    render json: client.get_groups(id)
  end

  get("/:id/manager", :manager) do
    id = params["id"]
    case client.client_id
    when :office365
      render json: client.calendar.as(PlaceCalendar::Office365).client.get_user_manager(id).to_place_calendar
    else
      raise Error::NotImplemented.new("manager query is not available for #{client.client_id}")
    end
  end
end
