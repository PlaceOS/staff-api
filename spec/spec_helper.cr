require "spec"

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

def truncate_db
  Clear::SQL.execute("TRUNCATE TABLE bookings CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE event_metadatas CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE guests CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE attendees CASCADE;")
  Clear::SQL.execute("TRUNCATE TABLE tenants CASCADE;")
end

Spec.before_each &->WebMock.reset

def office_mock_token
  UserJWT.new(
    iss: "staff-api",
    iat: Time.local,
    exp: Time.local + 1.week,
    aud: "toby.staff-api.dev",
    sub: "toby@redant.com.au",
    scope: ["public"],
    user: UserJWT::Metadata.new(
      name: "Toby Carvan",
      email: "dev@acaprojects.com",
      permissions: UserJWT::Permissions::Admin,
      roles: ["manage", "admin"]
    )
  ).encode
end

def office_guest_mock_token(guest_event_id, system_id)
  UserJWT.new(
    iss: "staff-api",
    iat: Time.local,
    exp: Time.local + 1.week,
    aud: "toby.staff-api.dev",
    sub: "toby@redant.com.au",
    scope: ["guest"],
    user: UserJWT::Metadata.new(
      name: "Jon Jon",
      email: "jon@example.com",
      permissions: UserJWT::Permissions::Admin,
      roles: [guest_event_id, system_id]
    )
  ).encode
end

def google_mock_token
  UserJWT.new(
    iss: "staff-api",
    iat: Time.local,
    exp: Time.local + 1.week,
    aud: "google.staff-api.dev",
    sub: "amit@redant.com.au",
    scope: ["public", "guest"],
    user: UserJWT::Metadata.new(
      name: "Amit Gaur",
      email: "amit@redant.com.au",
      permissions: UserJWT::Permissions::Admin,
      roles: ["manage", "admin"]
    )
  ).encode
end

def mock_tenant_params
  {
    name:        "Toby",
    platform:    "office365",
    domain:      "toby.staff-api.dev",
    credentials: %({"tenant":"bb89674a-238b-4b7d-91ec-6bebad83553a","client_id":"6316bc86-b615-49e0-ad24-985b39898cb7","client_secret": "k8S1-0c5PhIh:[XcrmuAIsLo?YA[=-GS"}),
  }
end

# Provide some basic headers for office365 auth
OFFICE365_HEADERS = HTTP::Headers{
  "Host"          => "toby.staff-api.dev",
  "Authorization" => "Bearer #{office_mock_token}",
}

# Provide some basic headers for office365 auth
def office365_guest_headers(guest_event_id, system_id)
  HTTP::Headers{
    "Host"          => "toby.staff-api.dev",
    "Authorization" => "Bearer #{office_guest_mock_token(guest_event_id, system_id)}",
  }
end

# Provide some basic headers for google auth
GOOGLE_HEADERS = HTTP::Headers{
  "Host"          => "google.staff-api.dev",
  "Authorization" => "Bearer #{google_mock_token}",
}

def extract_http_status(response)
  split_res(response)[0].split(" ")[1]
end

def extract_json(response)
  JSON.parse(extract_body(response))
end

def extract_body(response)
  split_res(response)[-1]
end

private def split_res(response)
  response.to_s.split("\r\n").reject(&.empty?)
end

module TenantsHelper
  extend self

  def create_tenant(params = mock_tenant_params)
    tenant = Tenant.new(params)
    tenant.save
    tenant
  end
end

module EventMetadatasHelper
  extend self

  def create_event(tenant_id,
                   id,
                   event_start = Time.utc.to_unix,
                   event_end = 60.minutes.from_now.to_unix,
                   system_id = "sys_id",
                   room_email = "room@example.com",
                   host = "user@example.com",
                   ext_data = JSON.parse({"foo": 123}.to_json),
                   ical_uid = "random_uid")
    meta = EventMetadata.new
    meta.tenant_id = tenant_id
    meta.system_id = system_id
    meta.event_id = id
    meta.host_email = host
    meta.resource_calendar = room_email
    meta.event_start = event_start
    meta.event_end = event_end
    meta.ext_data = ext_data
    meta.ical_uid = ical_uid
    meta.save!

    meta
  end
end
