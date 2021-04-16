require "../spec_helper"

describe Tenant do
  it "valid input raises no errors" do
    a = TenantsHelper.create_tenant({
      name:        "Jon",
      platform:    "google",
      domain:      "google.staff-api.dev",
      credentials: %({"issuer":"1122121212","scopes":["http://example.com"],"signing_key":"-----BEGIN PRIVATE KEY-----SOMEKEY DATA-----END PRIVATE KEY-----","domain":"example.com.au","sub":"jon@example.com.au"}),
    })
    a.errors.size.should eq 0
  end

  it "should accept JSON params" do
    body = %({
      "name":        "Bob",
      "platform":    "google",
      "domain":      "club-bob.staff-api.dev",
      "credentials": {
        "issuer":      "1122121212",
        "scopes":      ["http://example.com"],
        "signing_key": "-----BEGIN PRIVATE KEY-----SOMEKEY DATA-----END PRIVATE KEY-----",
        "domain":      "example.com.au",
        "sub":         "bob@example.com.au"
      }
    })

    headers = {
      "Host"          => "google.staff-api.dev",
      "Authorization" => "Bearer #{Mock::Token.google}",
      "Content-Type"  => "application/json",
    }

    res = Tenants.context("POST", "/api/staff/v1/tenants", body: body, headers: headers, &.create)
    res.status_code.should eq(200)
  end

  it "takes JSON credentials and returns a PlaceCalendar::Client" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.place_calendar_client.class.should eq(PlaceCalendar::Client)
  end

  it "should validate credentials based on platform" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.update({platform: "google"})
    a.errors.size.should be > 0
  end
end

module TenantsHelper
  extend self

  MOCK_TENANT_PARAMS = {
    name:        "Toby",
    platform:    "office365",
    domain:      "toby.staff-api.dev",
    credentials: %({"tenant":"bb89674a-238b-4b7d-91ec-6bebad83553a","client_id":"6316bc86-b615-49e0-ad24-985b39898cb7","client_secret": "k8S1-0c5PhIh:[XcrmuAIsLo?YA[=-GS"}),
  }

  def create_tenant(params = MOCK_TENANT_PARAMS)
    Tenant.create(params)
  end
end
