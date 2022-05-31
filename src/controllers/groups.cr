class Groups < Application
  base "/api/staff/v1/groups"

  def index
    query = params["q"]?
    if client.client_id == :office365
      render json: client.calendar.as(PlaceCalendar::Office365).client.list_groups(query).value.map(&.to_place_group)
    else
      raise Error::NotImplemented.new("group listing is not available for #{client.client_id}")
    end
  end

  def show
    id = params["id"]
    if client.client_id == :office365
      render json: client.calendar.as(PlaceCalendar::Office365).client.get_group(id).to_place_group
    else
      raise Error::NotImplemented.new("group is not available for #{client.client_id}")
    end
  end

  get("/:id/members", :members) do
    group_id = params["id"]
    render json: client.get_members(group_id)
  end
end
