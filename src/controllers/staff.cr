class Staff < Application
  base "/api/staff/v1/people"

  # Retrieves a list of users from the organization directory
  # This function supports advanced filtering using Azure AD filter syntax.
  # For more information on Azure AD filter syntax, visit:
  # https://learn.microsoft.com/en-us/graph/filter-query-parameter?tabs=http
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "q", description: "An optional search query to filter users by name or email. If both 'q' and 'filter' parameters are provided, 'filter' takes precedence.", example: "steve")]
    query : String? = nil,
    @[AC::Param::Info(name: "filter", description: "An optional advanced search filter using Azure AD filter syntax. Provides more control over the search criteria and takes precedence over the 'q' parameter. Supports both Azure AD and Google providers.", example: "startsWith(givenName,'ben') or startsWith(surname,'ben')")]
    filter : String? = nil,
    @[AC::Param::Info(description: "a google token or graph api URI representing the next page of results")]
    next_page : String? = nil,
  ) : Array(PlaceCalendar::User)
    users = if filter
              client.list_users(filter: filter, next_link: next_page)
            else
              client.list_users(query, next_link: next_page)
            end

    if next_link = users.first?.try(&.next_link)
      params = URI::Params.build do |form|
        form.add("q", query.as(String).strip) if query.presence
        form.add("filter", filter) if filter
        form.add("next_page", next_link)
      end
      response.headers["Link"] = %(</api/staff/v1/people?#{params}>; rel="next")
    end

    if client.client_id == :office365
      users.map! do |user|
        user.photo = "/api/staff/v1/people/#{user.email}/photo"
        user
      end
    end
    users
  end

  # returns user details for the id provided
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(description: "a user id OR user email address", example: "user@org.com")]
    id : String,
  ) : PlaceCalendar::User
    if id.includes?('@')
      user = client.get_user_by_email(id)
    else
      user = client.get_user(id)
    end
    raise Error::NotFound.new("user #{id} not found") unless user

    if client.client_id == :office365
      user.photo = "/api/staff/v1/people/#{user.email}/photo"
    end

    user
  end

  # returns user photo
  @[AC::Route::GET("/:id/photo")]
  def photo(
    @[AC::Param::Info(description: "a user id OR user email address", example: "user@org.com")]
    id : String,
  ) : Nil
    if client.client_id == :office365
      # get current users token
      # NOTE: we should move this rest-api function into models
      # so we can access it from staff-api. This will improve performance
      token = get_placeos_client.users.resource_token

      # make request to the photo endpoint
      HTTP::Client.get("https://graph.microsoft.com/v1.0/users/#{id}/photo/$value", headers: HTTP::Headers{
        "Authorization" => "Bearer #{token.token}",
      }) do |upstream_response|
        stream(upstream_response)
      end
    else
      # Google ids are always emails
      user = client.get_user_by_email(id)
      raise Error::NotFound.new("user #{id} not found") unless user
      photo = user.photo
      raise Error::NotFound.new("user #{id} doesn't have a photo") unless photo

      HTTP::Client.get(photo) do |upstream_response|
        stream(upstream_response)
      end
    end
  end

  private def stream(upstream_response)
    # Set the response status code
    @__render_called__ = true
    response.status_code = upstream_response.status_code

    # Copy headers from the upstream response, excluding 'Transfer-Encoding'
    upstream_response.headers.each do |key, value|
      response.headers[key] = value unless key.downcase == "transfer-encoding"
    end

    # Stream the response body directly to the client
    if body_io = upstream_response.body_io?
      IO.copy(body_io, response)
    else
      response.print upstream_response.body
    end
  end

  # returns the list of groups the user is a member
  @[AC::Route::GET("/:id/groups")]
  def groups(id : String) : Array(PlaceCalendar::Group)
    client.get_groups(id)
  end

  # returns the users manager
  @[AC::Route::GET("/:id/manager")]
  def manager(id : String) : PlaceCalendar::User
    case client.client_id
    when :office365
      client.calendar.as(PlaceCalendar::Office365).client.get_user_manager(id).to_place_calendar
    else
      raise Error::NotImplemented.new("manager query is not available for #{client.client_id}")
    end
  end

  # returns the list of public calendars
  @[AC::Route::GET("/:id/calendars")]
  def calendars(id : String) : Array(PlaceCalendar::Calendar)
    client.list_calendars(id)
  end
end
