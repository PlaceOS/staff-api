require "../spec_helper"

describe Tenant do
  it "valid input raises no errors" do
    params = {
      name:        "Jon",
      platform:    "google",
      domain:      "google.staff-api.dev",
      credentials: %({"issuer":"1122121212","scopes":["http://example.com"],"signing_key":"-----BEGIN PRIVATE KEY-----SOMEKEY DATA-----END PRIVATE KEY-----","domain":"example.com.au","sub":"jon@example.com.au"}),
    }
    a = TenantsHelper.create_tenant(params)
    a.errors.size.should eq 0
  end

  it "takes JSON credentials and returns a PlaceCalendar::Client" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.place_calendar_client.class.should eq(PlaceCalendar::Client)
  end

  it "should validate credentials based on platform" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.platform = "google"
    a.save
    a.errors.size.should be > 0
  end
end
