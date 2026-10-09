# Place, the room resources (room mailboxes) defined in the tenant's Office365 directory. Use systems for PlaceOS rooms
class Place < Application
  base "/api/staff/v1/place"

  # Lists the room resources defined in the Office365 directory (Microsoft Graph places API).
  # Supports Azure AD filter syntax, see https://learn.microsoft.com/en-us/graph/filter-query-parameter
  # Use `top` and `skip` to page through results. Office365 only, returns 501 (not implemented) for Google.
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "match", description: "optional comma separated list of room properties to return (maps to the graph `$select` parameter)", example: "id,displayName,emailAddress")]
    match : String? = nil,
    @[AC::Param::Info(name: "filter", description: "optional filter using Azure AD filter syntax (maps to the graph `$filter` parameter)", example: "startsWith(displayName,'Board')")]
    filter : String? = nil,
    @[AC::Param::Info(description: "optional maximum number of rooms to return (maps to the graph `$top` parameter, graph defaults to 100)", example: "100")]
    top : Int32? = nil,
    @[AC::Param::Info(description: "optional number of rooms to skip, for paging (maps to the graph `$skip` parameter)", example: "100")]
    skip : Int32? = nil,
  ) : Array(Office365::Room)
    case client.client_id
    when :office365
      client.calendar.as(PlaceCalendar::Office365).client.list_rooms(match: match, filter: filter, top: top, skip: skip).as(Office365::Rooms).value
    else
      raise Error::NotImplemented.new("place query is not available for #{client.client_id}")
    end
  end
end
