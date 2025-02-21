class Place < Application
  base "/api/staff/v1/place"

  # Retrieves a list of rooms from the tenant place object
  # This function supports advanced filtering using Azure AD filter syntax.
  # For more information on Azure AD filter syntax, visit:
  # https://learn.microsoft.com/en-us/graph/filter-query-parameter?tabs=http
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "match", description: "An optional query parameter to return a subset of properties for a resource. With match, you can specify a subset or a superset of the default properties.", example: "id,displayName")]
    match : String? = nil,
    @[AC::Param::Info(name: "filter", description: "An optional advanced search filter using Azure AD filter syntax to query parameter to retrieve a subset of a collection..", example: "startsWith(givenName,'ben') or startsWith(surname,'ben')")]
    filter : String? = nil,
    @[AC::Param::Info(description: "Optional: Use the top query parameter to specify the number of items to be included in the result. Default value is 100", example: "100")]
    top : Int32? = nil,
    @[AC::Param::Info(description: "Optional: Use skip query parameter to set the number of items to skip at the start of a collection.", example: "21 to retrieve search results from 21st record")]
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
