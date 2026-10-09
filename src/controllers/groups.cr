# Groups, the user groups in the tenant's Office365 or Google directory and their members
class Groups < Application
  base "/api/staff/v1/groups"

  # queue requests on a per-user basis
  @[AC::Route::Filter(:around_action)]
  Application.add_request_queue

  # Lists the user groups in the organisation directory, optionally searching by name.
  # Office365 only, returns 501 (not implemented) for Google.
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "q", description: "optional search query, matches groups whose display name starts with this text", example: "accounting")]
    query : String? = nil,
  ) : Array(PlaceCalendar::Group)
    if client.client_id == :office365
      client.calendar.as(PlaceCalendar::Office365).client.list_groups(query).value.map(&.to_place_group)
    else
      raise Error::NotImplemented.new("group listing is not available for #{client.client_id}")
    end
  end

  # Returns the details of a directory group. Office365 only, returns 501 (not implemented) for Google.
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(description: "the directory group id", example: "0b4ad8b6-4a4a-4bcd-9a1e-3b2f0b6b1c2d")]
    id : String,
  ) : PlaceCalendar::Group
    if client.client_id == :office365
      client.calendar.as(PlaceCalendar::Office365).client.get_group(id).to_place_group
    else
      raise Error::NotImplemented.new("group is not available for #{client.client_id}")
    end
  end

  # Returns the staff members of a directory group.
  @[AC::Route::GET("/:id/members")]
  def members(
    @[AC::Param::Info(description: "the directory group id", example: "0b4ad8b6-4a4a-4bcd-9a1e-3b2f0b6b1c2d")]
    id : String,
  ) : Array(PlaceCalendar::Member)
    client.get_members(id)
  end
end
