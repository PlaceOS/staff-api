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

  # establishes a session, returning the headers to use for it
  open_session = ->(credentials : HTTP::Headers) {
    headers = mcp_headers.call(credentials)
    response = rpc.call(headers, "initialize", initialize_params)
    response.status_code.should eq 200
    headers["Mcp-Session-Id"] = response.headers["Mcp-Session-Id"]
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
    toolboxes.should contain "users"

    description = ActionController::MCPServer.description
    controllers = description.toolboxes.map(&.controller)
    {HealthCheck, Admin, Outlook}.each do |hidden|
      controllers.should_not contain hidden.name
    end

    description.tool?("staff_photo").should be_nil
    description.tool?("events_notify_change").should be_nil
    description.tool?("events_link_master_metadata").should be_nil
    description.tool?("staff_show").should_not be_nil
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
