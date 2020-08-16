require "../spec_helper"

describe Tenant do
  it "valid input raises no errors" do
    a = Tenant.new({
      name: "Toby", 
      platform: "office365", 
      domain: "toby.staff-api.dev",
      credentials: %({"tenant":"123","client_id":"123","client_secret":"123"})
    })
    a.save
    a.errors.size.should eq 0
  end

  it "takes JSON credentials and returns a NamedTuple which can be passed to PlaceCalendar" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.place_calendar_params.class.should eq(NamedTuple(tenant: String, client_id: String, client_secret: String))
  end

  it "should validte credentials based on platform" do
    a = Tenant.query.find! { domain == "toby.staff-api.dev" }
    a.platform = "google"
    a.save
    a.errors.size.should be > 0
  end
end
