require "../spec_helper"
require "placeos-models/spec/generator"

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

  with_server do
    it "prevents two tenants with the same domain" do
      WebMock.allow_net_connect = true
      path = "/api/staff/v1/tenants"

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

      curl(
        method: "POST",
        path: path,
        body: body,
        headers: Mock::Headers.office365_guest,
      )

      body = %({
      "name":        "Ian",
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

      response = curl(
        method: "POST",
        path: path,
        body: body,
        headers: Mock::Headers.office365_guest,
      )

      response.status_code.should eq 422
      response.body.should match(App::PG_UNIQUE_CONSTRAINT_REGEX)
      WebMock.reset
    end
  end

  it "should accept JSON params" do
    body = %({
      "name":        "Bob",
      "platform":    "google",
      "domain":      "club-bob2.staff-api.dev",
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

  it "should accept booking limits" do
    a = TenantsHelper.create_tenant({
      name:           "Jon2",
      platform:       "google",
      domain:         "google.staff-api.dev",
      credentials:    %({"issuer":"1122121212","scopes":["http://example.com"],"signing_key":"-----BEGIN PRIVATE KEY-----SOMEKEY DATA-----END PRIVATE KEY-----","domain":"example.com.au","sub":"jon@example.com.au"}),
      booking_limits: %({"desk": 2}),
    })
    a.errors.size.should eq 0
    a.booking_limits.should eq({"desk" => 2})
  end

  it "should validate booking limits" do
    a = TenantsHelper.create_tenant({
      name:           "Jon2",
      platform:       "google",
      domain:         "google.staff-api.dev",
      credentials:    %({"issuer":"1122121212","scopes":["http://example.com"],"signing_key":"-----BEGIN PRIVATE KEY-----SOMEKEY DATA-----END PRIVATE KEY-----","domain":"example.com.au","sub":"jon@example.com.au"}),
      booking_limits: %({"desk": "2"}),
    })
    a.errors.size.should eq 1
  end

  it "check encryption" do
    t = TenantsHelper.create_tenant({
      name:        "Jon2",
      platform:    "google",
      domain:      "encrypt.google.staff-api.dev",
      credentials: %({"issuer":"1122121212","scopes":["http://example.com"],"signing_key":"-----BEGIN PRIVATE KEY-----SOMEKEY DATA-----END PRIVATE KEY-----","domain":"example.com.au","sub":"jon@example.com.au"}),
    })
    t.is_encrypted?.should be_true
  end

  describe "#decrypt_for" do
    tenant = TenantsHelper.create_tenant
    UserJWT::Permissions.each do |permission|
      it "does not decrypt for #{permission.to_json}" do
        token = TenantsHelper.create_token(permission)
        PlaceOS::Encryption.is_encrypted?(tenant.decrypt_for(token)).should be_true
      end
    end
  end

  it "takes JSON credentials and returns a PlaceCalendar::Client" do
    tenant = get_tenant
    tenant.place_calendar_client.class.should eq(PlaceCalendar::Client)
  end

  it "should validate credentials based on platform" do
    tenant = get_tenant
    tenant.update({platform: "google"})
    tenant.errors.size.should be > 0
  end
end

module TenantsHelper
  extend self

  MOCK_TENANT_PARAMS = {
    name:        "Toby",
    platform:    "office365",
    domain:      "toby.staff-api.dev",
    credentials: %({"tenant":"bb89674a-238b-4b7d-91ec-6bebad83553a","client_id":"6316bc86-b615-49e0-ad24-985b39898cb7","client_secret": "k8S1-0c5PhIh:[XcrmuAIsLo?YA[=-GS"}),
    delegated:   false,
  }

  def create_tenant(params = MOCK_TENANT_PARAMS)
    Tenant.create(params)
  end

  def create_token(level : UserJWT::Permissions = UserJWT::Permissions::User)
    UserJWT.new(
      Faker::Lorem.word,
      Time.local,
      Time.local + 24.hours,
      Faker::Internet.domain_name,
      "123",
      UserJWT::Metadata.new(
        Faker::Name.name,
        Faker::Internet.email,
        level
      )
    )
  end
end
