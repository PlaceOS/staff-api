class Groups < Application
  base "/api/staff/v1/groups"

  # returns a list of user groups in the orgainisations directory
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "q", description: "optional search query", example: "accounting")]
    query : String? = nil
  ) : Array(PlaceCalendar::Group)
    if client.client_id == :office365
      client.calendar.as(PlaceCalendar::Office365).client.list_groups(query).value.map(&.to_place_group)
    else
      raise Error::NotImplemented.new("group listing is not available for #{client.client_id}")
    end
  end

  # returns the details of the provided group id
  @[AC::Route::GET("/:id")]
  def show(id : String) : PlaceCalendar::Group
    if client.client_id == :office365
      client.calendar.as(PlaceCalendar::Office365).client.get_group(id).to_place_group
    else
      raise Error::NotImplemented.new("group is not available for #{client.client_id}")
    end
  end

  # returns the list of staff memebers in a particular user group
  @[AC::Route::GET("/:id/members")]
  def members(id : String) : Array(PlaceCalendar::Member)
    client.get_members(id)
  end
end
