require "../spec_helper"

describe App::MCP do
  router = ActionController::SpecHelper.new
  App::MCP.mount(router)
  mcp_client = router.hot_topic
  domain = "toby.staff-api.dev"

  mcp_headers = ->(credentials : HTTP::Headers) {
    headers = credentials.dup
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json"
    headers["Host"] = domain
    headers
  }
  rpc = ->(headers : HTTP::Headers, method : String, params : Hash(String, JSON::Any)) {
    body = {jsonrpc: "2.0", id: 1, method: method, params: params}.to_json
    mcp_client.post(App::MCP::PATH, headers: headers, body: body)
  }
  initialize_params = {"protocolVersion" => JSON::Any.new("2025-11-25")}
  no_params = {} of String => JSON::Any

  # initializes the stateless server, returning the headers to use for later requests
  open_session = ->(credentials : HTTP::Headers) {
    headers = mcp_headers.call(credentials)
    response = rpc.call(headers, "initialize", initialize_params)
    response.status_code.should eq 200
    headers
  }
  call_tool = ->(headers : HTTP::Headers, name : String, arguments : Hash(String, JSON::Any)) {
    response = rpc.call(headers, "tools/call", {"name" => JSON::Any.new(name), "arguments" => JSON::Any.new(arguments)})
    response.status_code.should eq 200
    JSON.parse(response.body)["result"]
  }
  # runs a tool from an open toolbox via one of the proxy tools
  proxy = ->(headers : HTTP::Headers, via : String, name : String, arguments : Hash(String, JSON::Any)) {
    call_tool.call(headers, via, {"name" => JSON::Any.new(name), "arguments" => JSON::Any.new(arguments)})
  }
  bearer = -> { HTTP::Headers{"Authorization" => "Bearer #{Mock::Token.office}"} }

  it "challenges unauthenticated clients with the protected resource metadata" do
    response = rpc.call(mcp_headers.call(HTTP::Headers.new), "initialize", initialize_params)
    response.status_code.should eq 401
    response.headers["WWW-Authenticate"].should eq %(Bearer resource_metadata="https://#{domain}/.well-known/oauth-protected-resource/api/staff/v1/mcp", scope="public")
    response.headers["Mcp-Session-Id"]?.should be_nil
  end

  it "points clients at the authorization server on the same host" do
    response = mcp_client.get("/.well-known/oauth-protected-resource#{App::MCP::PATH}", headers: HTTP::Headers{"Host" => domain, "X-Forwarded-Proto" => "https"})
    response.status_code.should eq 200
    JSON.parse(response.body)["authorization_servers"].as_a.map(&.as_s).should eq ["https://#{domain}"]
  end

  it "authenticates with the current user route, which any signed in user can reach" do
    App::MCP::AUTH_PROBE.should eq "/api/staff/v1/users/current"
    mcp_client.get(App::MCP::AUTH_PROBE, headers: HTTP::Headers{"Host" => domain}.merge!(bearer.call)).status_code.should eq 200
  end

  it "tells the model which tools show cards" do
    headers = mcp_headers.call(bearer.call)
    instructions = JSON.parse(rpc.call(headers, "initialize", initialize_params).body)["result"]["instructions"].as_s
    {"bookings_book, events_book, staff_index, spaces_index, calendars_availability and the show tools display a card"}.each do |text|
      instructions.gsub(/\s+/, " ").should contain text.gsub(/\s+/, " ")
    end
  end

  it "rejects invalid credentials" do
    headers = mcp_headers.call(HTTP::Headers{"Authorization" => "Bearer not-a-token"})
    response = rpc.call(headers, "initialize", initialize_params)
    response.status_code.should eq 401
    response.headers["WWW-Authenticate"].should contain %(error="invalid_token")
  end

  it "rejects tokens issued for another domain" do
    headers = mcp_headers.call(bearer.call)
    headers["Host"] = "another.domain.dev"
    response = rpc.call(headers, "initialize", initialize_params)
    response.status_code.should eq 401
  end

  it "accepts bearer tokens and API keys" do
    open_session.call(bearer.call)

    Mock::Token.generate_auth_user(false, false)
    authority = PlaceOS::Model::Authority.find_by_domain(domain).not_nil!
    key = PlaceOS::Model::Generator.api_key(authority)
    token = key.x_api_key.not_nil!
    key.save!
    open_session.call(HTTP::Headers{"X-API-Key" => token})
  ensure
    key.try &.destroy
  end

  it "lists the API resources as toolboxes, excluding the unsuitable routes" do
    headers = open_session.call(bearer.call)

    toolboxes = call_tool.call(headers, "list_toolboxes", no_params)["structuredContent"]["toolboxes"].as_a.map(&.["name"].as_s)
    toolboxes.should contain "bookings"
    toolboxes.should contain "events"
    toolboxes.should contain "guests"
    toolboxes.should contain "surveys_questions"
    toolboxes.should contain "spaces"
    # users only has the root current user tool, so it isn't a toolbox
    toolboxes.should_not contain "users"
    toolboxes.should contain "desks"

    description = ActionController::MCPServer.description
    controllers = description.toolboxes.map(&.controller)
    {HealthCheck, Admin, Outlook}.each do |hidden|
      controllers.should_not contain hidden.name
    end

    # the photo is a binary stream, only the staff card loads it
    _toolbox, photo = description.tool?("staff_photo").not_nil!
    photo.visibility.should eq ["card"]
    # the booking card loads the asset's level map
    _toolbox, map = description.tool?("assets_map").not_nil!
    map.visibility.should eq ["card"]
    # and the space card the space's photos and level map
    {"spaces_image", "spaces_map"}.each do |name|
      _toolbox, tool = description.tool?(name).not_nil!
      tool.visibility.should eq ["card"]
    end
    description.tool?("events_notify_change").should be_nil
    description.tool?("events_link_master_metadata").should be_nil
    description.tool?("staff_show").should_not be_nil
  end

  it "lists the desk booking prompt without opening a toolbox" do
    headers = open_session.call(bearer.call)
    prompts = JSON.parse(rpc.call(headers, "prompts/list", no_params).body)["result"]["prompts"].as_a
    prompts.map(&.["name"].as_s).should contain "desks_book"

    params = {"name" => JSON::Any.new("desks_book"), "arguments" => JSON::Any.new({"date" => JSON::Any.new("tomorrow"), "near" => JSON::Any.new("Jane")})}
    result = JSON.parse(rpc.call(headers, "prompts/get", params).body)["result"]
    text = result["messages"][0]["content"]["text"].as_s
    text.should start_with "Book me a desk for tomorrow near Jane."
    {"desks_index", "desks_nearby", "bookings_book", "spaces_zones"}.each { |tool| text.should contain tool }
  end

  it "lists the meeting room booking prompt without opening a toolbox" do
    headers = open_session.call(bearer.call)
    prompts = JSON.parse(rpc.call(headers, "prompts/list", no_params).body)["result"]["prompts"].as_a
    prompts.map(&.["name"].as_s).should contain "spaces_book"

    arguments = {"time" => "tomorrow 2pm, 1 hour", "attendees" => "Jane", "size" => "4", "needs" => "vidconf"}
    params = {"name" => JSON::Any.new("spaces_book"), "arguments" => JSON::Any.new(arguments.transform_values { |value| JSON::Any.new(value) })}
    text = JSON.parse(rpc.call(headers, "prompts/get", params).body)["result"]["messages"][0]["content"]["text"].as_s
    text.should start_with "Book me a meeting room for tomorrow 2pm, 1 hour with Jane for 4 people with vidconf."
    {"calendars_availability", "calendars_free_busy", "events_book", "spaces_zones", "users_current"}.each { |tool| text.should contain tool }
  end

  it "lists the prompts for checking my bookings and meetings without opening a toolbox" do
    headers = open_session.call(bearer.call)
    prompts = JSON.parse(rpc.call(headers, "prompts/list", no_params).body)["result"]["prompts"].as_a.map(&.["name"].as_s)
    {"bookings_mine", "events_mine"}.each { |name| prompts.should contain name }

    render = ->(name : String, arguments : Hash(String, String)) {
      params = {"name" => JSON::Any.new(name), "arguments" => JSON::Any.new(arguments.transform_values { |value| JSON::Any.new(value) })}
      JSON.parse(rpc.call(headers, "prompts/get", params).body)["result"]["messages"][0]["content"]["text"].as_s
    }

    bookings = render.call("bookings_mine", {"period" => "this week", "type" => "desk"})
    bookings.should start_with "What desk bookings do I have this week?"
    {"bookings_index", "bookings_show", "bookings_destroy"}.each { |tool| bookings.should contain tool }
    render.call("bookings_mine", {} of String => String).should start_with "What bookings do I have today?"

    events = render.call("events_mine", {"period" => "tomorrow"})
    events.should start_with "What meetings do I have tomorrow?"
    {"events_index", "events_show", "calendars_free_busy"}.each { |tool| events.should contain tool }

    # desks go near my meetings and rooms near my desk
    render.call("desks_book", {} of String => String).should contain "events_index"
    render.call("spaces_book", {} of String => String).should contain "type desk"
  end

  it "marks the clash checks as read only, although they're POST requests" do
    description = ActionController::MCPServer.description
    {"bookings_clashing_assets", "events_clashing_assets"}.each do |name|
      _toolbox, tool = description.tool?(name).not_nil!
      tool.read_only?.should be_true
    end
    _toolbox, create = description.tool?("bookings_create").not_nil!
    create.read_only?.should be_false
  end

  it "lists every tool the cards call without opening a toolbox" do
    # hosts only let cards call tools in their tool list
    called = Dir.glob("./cards/*/card.html").flat_map do |card|
      File.read(card).scan(/name: "(\w+)", arguments|(?:callTool|callImage|loadMap)\("(\w+)"/).map { |match| match[1]? || match[2] }
    end.uniq!
    called.size.should be > 10

    headers = open_session.call(bearer.call)
    listed = JSON.parse(rpc.call(headers, "tools/list", no_params).body)["result"]["tools"].as_a.map(&.["name"].as_s)
    (called - listed).should be_empty
  end

  it "lists the space card and booking tools without opening a toolbox" do
    headers = open_session.call(bearer.call)
    tools = JSON.parse(rpc.call(headers, "tools/list", no_params).body)["result"]["tools"].as_a
    names = tools.map(&.["name"].as_s)
    {"events_book", "events_edit", "events_destroy", "bookings_book", "bookings_edit", "bookings_destroy", "users_current", "desks_nearby", "desks_index", "desks_near_colleagues"}.each { |name| names.should contain name }
    # the full create and update tools stay in their toolboxes, their schemas are large
    {"events_create", "events_update", "bookings_update"}.each { |name| names.should_not contain name }
    # booking and searching show their results' cards, no follow-up show call needed
    {
      "bookings_show" => "bookings", "bookings_book" => "bookings", "events_show" => "events",
      "events_book" => "events", "staff_show" => "staff", "staff_index" => "staff",
      "spaces_index" => "spaces", "calendars_availability" => "spaces",
    }.each do |name, folder|
      tools.find!(&.["name"].==(name))["_meta"]["ui"]["resourceUri"].as_s.should start_with "ui://#{folder}/card.html?v="
    end

    show = tools.find!(&.["name"].==("spaces_show"))
    uri = show["_meta"]["ui"]["resourceUri"].as_s
    uri.should start_with "ui://spaces/card.html?v="

    contents = JSON.parse(rpc.call(headers, "resources/read", {"uri" => JSON::Any.new(uri)}).body)["result"]["contents"][0]
    contents["mimeType"].should eq "text/html;profile=mcp-app"
    contents["text"].as_s.should contain "events_book"
  end

  it "calls routes as the authenticated user" do
    headers = open_session.call(bearer.call)
    tenant = get_tenant
    tenant.booking_limits = JSON.parse(%({"desk": 2}))
    tenant.save!

    call_tool.call(headers, "open_toolbox", {"name" => JSON::Any.new("tenants")})["isError"].should be_false
    result = call_tool.call(headers, "tenants_current_limits", no_params)
    result["isError"].should be_false
    # the route's response is returned as {status, headers, body}
    result["structuredContent"]["status"].should eq 200
    result["structuredContent"]["body"]["desk"].should eq 2
  end

  it "runs reads with call_read_only and refuses changes" do
    headers = open_session.call(bearer.call)
    call_tool.call(headers, "open_toolbox", {"name" => JSON::Any.new("tenants")})

    result = proxy.call(headers, "call_read_only", "tenants_current_limits", no_params)
    result["isError"].should be_false

    tenant = get_tenant
    result = proxy.call(headers, "call_read_only", "tenants_update_limits", {
      "id"     => JSON::Any.new(tenant.id.not_nil!),
      "limits" => JSON.parse(%({"desk": 5})),
    })
    result["isError"].should be_true
    get_tenant.booking_limits["desk"]?.should_not eq 5
  end

  it "enforces the user's permissions on tool calls" do
    headers = open_session.call(HTTP::Headers{"Authorization" => "Bearer #{Mock::Token.normal_office_user("mcp-user@example.com")}"})
    call_tool.call(headers, "open_toolbox", {"name" => JSON::Any.new("tenants")})

    # tenant management is admin only
    result = call_tool.call(headers, "tenants_index", no_params)
    result["isError"].should be_true
  end

  it "challenges clients whose token stops working mid-session" do
    headers = open_session.call(bearer.call)
    headers["Authorization"] = "Bearer expired.or.revoked"
    response = rpc.call(headers, "tools/list", no_params)
    response.status_code.should eq 401
    response.headers["WWW-Authenticate"].should contain "resource_metadata="
  end
end
