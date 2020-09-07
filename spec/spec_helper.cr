require "spec"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"
require "webmock"

Spec.before_suite do
  truncate_db
end

Spec.before_each &->WebMock.reset

def truncate_db
  Clear::SQL.execute("TRUNCATE TABLE tenants CASCADE;")
end

def office_mock_token
  UserJWT.new(
    iss: "staff-api",
    iat: Time.local,
    exp: Time.local + 1.week,
    aud: "toby.staff-api.dev",
    sub: "toby@redant.com.au",
    scope: ["public", "guest"],
    user: UserJWT::Metadata.new(
      name: "Toby Carvan",
      email: "dev@acaprojects.com",
      permissions: UserJWT::Permissions::Admin,
      roles: ["manage", "admin"]
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

# Provide some basic headers for google auth
GOOGLE_HEADERS = HTTP::Headers{
  "Host"          => "google.staff-api.dev",
  "Authorization" => "Bearer #{google_mock_token}",
}

def extract_json(response)
  JSON.parse(response.to_s.split("\r\n").reject(&.empty?)[-1])
end
