require "../spec_helper"

describe Tenant do
  it "valid input raises no errors" do
    a = Tenant.new(mock_tenant_params)
    a.save
    a.errors.size.should eq 0
  end

  it "takes JSON credentials and returns a PlaceCalendar::Client" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.place_calendar_client.class.should eq(PlaceCalendar::Client)
  end

  it "should validte credentials based on platform" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.platform = "google"
    a.save
    a.errors.size.should be > 0
  end
end
