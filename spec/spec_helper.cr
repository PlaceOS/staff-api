require "spec"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"
require "webmock"

Spec.before_suite do
  WebMock.reset
  truncate_db
end

def truncate_db
  Clear::SQL.execute("TRUNCATE TABLE tenants;")
end

Spec.before_each &->WebMock.reset

# Grab the models generator
require "placeos-models"
require "../lib/placeos-models/spec/generator"

# Yield an authenticated user, and a header with Authorization bearer set
def authentication
  authority = PlaceOS::Model::Generator.authority("example.place.technology")
  authority.id = "sgrp-testing"

  authenticated_user = PlaceOS::Model::Generator.user(authority).not_nil!
  authenticated_user.email = authenticated_user.email.as(String) + Random.rand(9999).to_s
  authenticated_user.id = "user-testing"
  authenticated_user.authority = authority

  authorization_header = {
    "Authorization" => "Bearer #{PlaceOS::Model::Generator.jwt(authenticated_user).encode}",
  }
  {authenticated_user, authorization_header}
end

# Provide some basic headers for auth
HEADERS = HTTP::Headers{
  "Host"          => URI.parse(DOMAIN).host.as(String),
  "Authorization" => authentication[1]["Authorization"],
}

