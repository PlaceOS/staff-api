require "action-controller/mcp"

# Exposes the Staff API to LLM clients as an MCP server (Streamable HTTP).
#
# Controllers are toolboxes and their routes tools, see `ActionController::MCPServer`.
# Users authenticate with auth.cr (OAuth + PKCE): unauthenticated requests are
# challenged with the protected resource metadata, which auth.cr serves (nginx
# routes `/.well-known/*` to auth). API keys (`X-API-Key`) also work.
module App::MCP
  PATH = "/api/staff/v1/mcp"

  # any authenticated user of this domain: runs the full `authorize!`, scope and
  # token domain checks, without needing a tenant or a calendar connection
  AUTH_PROBE = "/api/staff/v1/users/current"

  INSTRUCTIONS = <<-TEXT
    PlaceOS Staff API: the workplace side of PlaceOS. Use it to find and book desks,
    car parking, lockers and other assets, manage calendar meetings and the rooms they
    use, register visitors, look up people in the organisation's directory and run
    workplace surveys. Every call is made as the signed in user, with their permissions.

    Key concepts:
    - the users toolbox's current user tool says who the signed in user is (name, email,
      department, work preferences). The staff toolbox searches the wider directory
    - bookings are PlaceOS records for desks, parking spaces, lockers, visitors and other
      assets, identified by `booking_type` and `asset_id`. events are meetings in the
      user's Office365 or Google calendar, where rooms are attendees (resource calendars)
    - a room is a PlaceOS system (`sys-...`) with a resource calendar email. Buildings,
      levels and areas are zones (`zone-...`). Find their ids with the PlaceOS (engine)
      API; this API takes them as filters (`zones`, `zone_ids`, `system_ids`)
    - times are unix epochs in seconds (`period_start`, `period_end`, `booking_start`,
      `event_start`...). Work them out in the user's time zone, a booking's `timezone`
      field says which zone it was made in
    - guests are visitors, recorded by email, who attend events and bookings

    Working well:
    - check availability before booking: the clashing assets tools and the calendar
      availability and free/busy tools report conflicts without changing anything
    - read before writing, and confirm with the user before cancelling, deleting or
      declining anything on their behalf. Prefer the user's own calendar unless asked
    - list results are paginated: follow the `Link` header (or use `X-Total-Count`)
    - a 511 response means the user needs to sign in to their calendar provider again,
      a 409 is a booking clash and a 410 a booking limit being reached
    TEXT

  # tokens are issued by auth.cr on the same host, its issuer is scheme + host
  def self.authorization_server(request : HTTP::Request) : String
    scheme = request.headers["X-Forwarded-Proto"]?.try(&.split(',').first.strip.presence) || (App.running_in_production? ? "https" : "http")
    "#{scheme}://#{request.hostname}"
  end

  def self.configure : Nil
    ActionController::MCPServer.tap do |mcp|
      mcp.server_name = "placeos-staff"
      mcp.server_version = App::VERSION
      mcp.instructions = "#{INSTRUCTIONS}\n\n#{mcp.toolbox_instructions}"
      mcp.description_path = ENV["MCP_DESCRIPTION_PATH"]? || "mcp.yml"
      mcp.auth_probe = AUTH_PROBE
      mcp.resource_metadata = ->(request : HTTP::Request) do
        ActionController::MCPServer::ResourceMetadata.new(
          authorization_servers: [authorization_server(request)],
          scopes_supported: ["public"],
        )
      end
    end
  end

  def self.mount(router : ActionController::Router) : ActionController::MCPServer::Transport
    ActionController::MCPServer.mount(router, PATH)
  end

  configure
end
