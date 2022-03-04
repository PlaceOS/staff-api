require "spec"
require "faker"
require "timecop"
require "uuid"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"
require "webmock"

Spec.before_suite do
  truncate_db
  # Since almost all specs need need tenant to work
  TenantsHelper.create_tenant
end

Spec.before_suite do
  # -Dquiet
  {% if flag?(:quiet) %}
    ::Log.setup(:warning)
  {% else %}
    ::Log.setup(:debug)
  {% end %}
end

def get_tenant
  Tenant.query.find! { domain == "toby.staff-api.dev" }
end

def truncate_db
  Clear::SQL.execute("TRUNCATE TABLE bookings CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE event_metadatas CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE guests CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE attendees CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE tenants CASCADE;")
end

Spec.before_each &->WebMock.reset

module Mock
  extend self

  module Token
    extend self

    # office_mock_token
    def office
      UserJWT.new(
        iss: "staff-api",
        iat: Time.local,
        exp: Time.local + 1.week,
        domain: "toby.staff-api.dev",
        id: "toby@redant.com.au",
        scope: [PlaceOS::Model::UserJWT::Scope::PUBLIC],
        user: UserJWT::Metadata.new(
          name: "Toby Carvan",
          email: "dev@acaprojects.com",
          permissions: UserJWT::Permissions::Admin,
          roles: ["manage", "admin"]
        )
      ).encode
    end

    # office_guest_mock_token
    def office_guest(guest_event_id, system_id)
      UserJWT.new(
        iss: "staff-api",
        iat: Time.local,
        exp: Time.local + 1.week,
        domain: "toby.staff-api.dev",
        id: "toby@redant.com.au",
        scope: [PlaceOS::Model::UserJWT::Scope::GUEST],
        user: UserJWT::Metadata.new(
          name: "Jon Jon",
          email: "jon@example.com",
          permissions: UserJWT::Permissions::Admin,
          roles: [guest_event_id, system_id]
        )
      ).encode
    end

    # google_mock_token
    def google
      UserJWT.new(
        iss: "staff-api",
        iat: Time.local,
        exp: Time.local + 1.week,
        domain: "google.staff-api.dev",
        id: "amit@redant.com.au",
        scope: [PlaceOS::Model::UserJWT::Scope::PUBLIC, PlaceOS::Model::UserJWT::Scope::GUEST],
        user: UserJWT::Metadata.new(
          name: "Amit Gaur",
          email: "amit@redant.com.au",
          permissions: UserJWT::Permissions::Admin,
          roles: ["manage", "admin"]
        )
      ).encode
    end
  end

  module Headers
    extend self

    # Provide some basic headers for office365 auth (office365_guest_headers)
    def office365_guest(guest_event_id = nil, system_id = nil)
      auth = (guest_event_id.nil? && system_id.nil?) ? Mock::Token.office : Mock::Token.office_guest(guest_event_id.not_nil!, system_id.not_nil!)
      {
        "Host"          => "toby.staff-api.dev",
        "Authorization" => "Bearer #{auth}",
      }
    end

    def google
      {
        "Host"          => "google.staff-api.dev",
        "Authorization" => "Bearer #{Mock::Token.google}",
      }
    end
  end
end

module EventMetadatasHelper
  extend self

  def create_event(tenant_id,
                   id = UUID.random.to_s,
                   event_start = Random.new.rand(5..19).minutes.from_now.to_unix,
                   event_end = Random.new.rand(25..79).minutes.from_now.to_unix,
                   system_id = "sys_id-#{Random.new.rand(500)}",
                   room_email = Faker::Internet.email,
                   host = Faker::Internet.email,
                   ext_data = JSON.parse({"foo": 123}.to_json),
                   ical_uid = "random_uid-#{Random.new.rand(500)}")
    EventMetadata.create!({
      tenant_id:         tenant_id,
      system_id:         system_id,
      event_id:          id,
      host_email:        host,
      resource_calendar: room_email,
      event_start:       event_start,
      event_end:         event_end,
      ext_data:          ext_data,
      ical_uid:          ical_uid,
    })
  end
end

module Context(T, M)
  extend self

  def response(method : String, route : String, route_params : Hash(String, String)? = nil, headers : Hash(String, String)? = nil, body : String | Bytes | IO | Nil = nil, &block)
    ctx = instantiate_context(method, route, route_params, headers, body)
    instance = T.new(ctx)
    yield instance
    ctx.response.output.rewind
    res = ctx.response

    body = if M == JSON::Any
             JSON.parse(res.output)
           else
             M.from_json(res.output)
           end

    {ctx.response.status_code, body}
  end

  def delete_response(method : String, route : String, route_params : Hash(String, String)? = nil, headers : Hash(String, String)? = nil, body : String | Bytes | IO | Nil = nil, &block)
    ctx = instantiate_context(method, route, route_params, headers, body)
    instance = T.new(ctx)
    yield instance
    ctx.response.output.rewind
    {ctx.response.status_code}
  end
end
