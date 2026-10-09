# People, the staff directory of the tenant's Office365 or Google organisation (search users, user details, managers, group memberships)
class Staff < Application
  base "/api/staff/v1/people"

  # Search the organisation directory for people.
  @[AC::Route::GET("/", converters: {additional_fields: ConvertStringArray})]
  def index(
    @[AC::Param::Info(name: "q", description: "An optional search query to filter users by name or email. If both 'q' and 'filter' parameters are provided, 'filter' takes precedence.", example: "steve")]
    query : String? = nil,
    @[AC::Param::Info(name: "filter", description: "An optional advanced search filter using Azure AD filter syntax. Provides more control over the search criteria and takes precedence over the 'q' parameter. Supports both Azure AD and Google providers.", example: "startsWith(givenName,'ben') or startsWith(surname,'ben')")]
    filter : String? = nil,
    @[AC::Param::Info(description: "the next page of results, a google page token or graph api URI. Normally taken from the `Link` header of the previous response")]
    next_page : String? = nil,
    @[AC::Param::Info(description: "a comma separated list of additional user fields to return (Office365 only)", example: "employeeId,department")]
    additional_fields : Array(String)? = nil,
  ) : Array(PlaceCalendar::User)
    search = filter ? nil : query
    users = if additional_fields && client.client_id == :office365
              client.list_users(search, filter: filter, next_link: next_page, additional_fields: additional_fields)
            else
              client.list_users(search, filter: filter, next_link: next_page)
            end

    if next_link = users.first?.try(&.next_link)
      params = URI::Params.build do |form|
        form.add("q", query.as(String).strip) if query.presence
        form.add("filter", filter) if filter
        form.add("additional_fields", additional_fields.join(',')) if additional_fields
        form.add("next_page", next_link)
      end
      response.headers["Link"] = %(</api/staff/v1/people?#{params}>; rel="next")
    end

    if client.client_id == :office365 && users.size > 0
      user_emails = users.map do |user|
        (user.username || user.email).as(String).strip.downcase
      end
      sql = "tags @> '{user-photo}'::text[] AND tags && '{#{user_emails.join(",")}}'::text[]"
      uploads = ::PlaceOS::Model::Upload.where(sql).to_a

      users.map! do |user|
        username = (user.username || user.email).as(String).strip.downcase
        if upload = uploads.find { |up| up.tags.last == username }
          user.photo = "/api/engine/v2/uploads/#{upload.id}/url"
        end
        user
      end
    end
    users
  end

  # Get a person from the directory.
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
      sql = "tags @> '{user-photo}'::text[] AND tags && '{#{(user.username || user.email).as(String).strip.downcase}}'::text[]"
      upload = ::PlaceOS::Model::Upload.where(sql).first?
      user.photo = "/api/engine/v2/uploads/#{upload.id}/url" if upload
    end

    user
  end

  # Get a person's photo.
  @[AC::MCP(hide: true)]
  @[AC::Route::GET("/:id/photo")]
  def photo(
    @[AC::Param::Info(description: "a user id OR user email address", example: "user@org.com")]
    id : String,
  ) : Nil
    if client.client_id == :office365
      token = current_user.resource_token

      # make request to the photo endpoint
      HTTP::Client.get("https://graph.microsoft.com/v1.0/users/#{URI.encode_path_segment(id)}/photo/$value", headers: HTTP::Headers{
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

  # List the directory groups a person is a member of.
  @[AC::Route::GET("/:id/groups")]
  def groups(
    @[AC::Param::Info(description: "a user id OR user email address", example: "user@org.com")]
    id : String,
  ) : Array(PlaceCalendar::Group)
    client.get_groups(id)
  end

  # Get a person's manager.
  @[AC::Route::GET("/:id/manager")]
  def manager(
    @[AC::Param::Info(description: "a user id OR user email address", example: "user@org.com")]
    id : String,
  ) : PlaceCalendar::User
    case client.client_id
    when :office365
      client.calendar.as(PlaceCalendar::Office365).client.get_user_manager(id).to_place_calendar
    else
      raise Error::NotImplemented.new("manager query is not available for #{client.client_id}")
    end
  end

  # List a person's calendars.
  @[AC::Route::GET("/:id/calendars")]
  def calendars(
    @[AC::Param::Info(description: "the user's email address", example: "user@org.com")]
    id : String,
  ) : Array(PlaceCalendar::Calendar)
    client.list_calendars(id)
  end
end
