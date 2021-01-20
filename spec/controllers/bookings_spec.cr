require "../spec_helper"
require "./helpers/spec_clean_up"

describe Bookings do
  describe "#index" do
    pending "should return a list of bookings" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      BookingsHelper.create_booking(tenant.id)
      BookingsHelper.create_booking(tenant_id: tenant.id,
        user_id: "bob@example.com",
        user_email: "bob@example.com",
        asset_id: "asset-2",
        zones: ["zone-4127", "zone-890"],
        booking_end: 30.minutes.from_now.to_unix)

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a
      body.size.should eq(2)

      # filter by zones
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=zone-890,zone-4127"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a
      body.size.should eq(1)

      # More filters by zones
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=zone-890"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a
      body.size.should eq(2)
    end

    it "should return a list of bookings when filtered by user" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      BookingsHelper.create_booking(tenant_id: tenant.id, user_id: "toby@redant.com.au")
      BookingsHelper.create_booking(tenant.id)

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      # Since we are using Toby's token to login, user=current means Toby
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=current"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq(["toby@redant.com.au"])

      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=jon@example.com"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq(["jon@example.com"])
    end
  end

  it "#show should find booking" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: OFFICE365_HEADERS, &.show)[1].as_h
    body["user_id"].should eq("jon@example.com")
    body["zones"].should eq(["zone-1234", "zone-4567", "zone-890"])
  end

  pending "#destroy should delete a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    BookingsHelper.create_booking(tenant.id)
    booking = BookingsHelper.create_booking(tenant_id: tenant.id,
      user_id: "bob@example.com",
      user_email: "bob@example.com",
      asset_id: "asset-2",
      zones: ["zone-4127", "zone-890"],
      booking_end: 30.minutes.from_now.to_unix)

    # Check both are returned in beginning
    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a
    body.size.should eq(2)

    Context(Bookings, JSON::Any).response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking.id.not_nil!.to_s}, headers: OFFICE365_HEADERS, &.destroy)[1].as_h

    # Check only one is returned after deletion
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a
    body.size.should eq(1)
  end

  it "#create should create and #update should update a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    created = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk"}), headers: OFFICE365_HEADERS, &.create)[1].as_h
    created["asset_id"].should eq("some_desk")
    created["booking_start"].should eq(starting)
    created["booking_end"].should eq(ending)

    # instantiate the controller
    updated = Context(Bookings, JSON::Any).response("PATCH", "#{BOOKINGS_BASE}/#{created["id"]}", route_params: {"id" => created["id"].to_s}, body: %({"extension_data":{"other":"stuff"}}), headers: OFFICE365_HEADERS, &.update)[1].as_h
    updated["extension_data"].as_h["other"].should eq("stuff")
    booking = Booking.query.find!({id: updated["id"]})
    booking.ext_data.not_nil!.as_h.should eq({"other" => "stuff"})
  end

  it "#approve should approve a booking and #reject should reject meeting" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/approve", route_params: {"id" => booking.id.to_s}, headers: OFFICE365_HEADERS, &.approve)[1].as_h
    body["approved"].should eq(true)
    body["approver_id"].should eq("toby@redant.com.au")
    body["approver_email"].should eq("dev@acaprojects.com")
    body["approver_name"].should eq("Toby Carvan")
    body["rejected"].should eq(false)

    # Test rejection
    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/reject", route_params: {"id" => booking.id.to_s}, headers: OFFICE365_HEADERS, &.reject)[1].as_h
    body["rejected"].should eq(true)
    body["approved"].should eq(false)
    # Reset approver info
    body["approver_id"].should eq(nil)
    body["approver_email"].should eq(nil)
    body["approver_name"].should eq(nil)
  end

  it "#check_in should set checked_in state of a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find!({domain: "toby.staff-api.dev"})
    booking = BookingsHelper.create_booking(tenant.id)

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: OFFICE365_HEADERS, &.check_in)[1].as_h
    body["checked_in"].should eq(true)

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", route_params: {"id" => booking.id.to_s}, headers: OFFICE365_HEADERS, &.check_in)[1].as_h
    body["checked_in"].should eq(false)
  end
end

BOOKINGS_BASE = Bookings.base_route

module BookingsHelper
  extend self

  def create_booking(tenant_id,
                     user_id = "jon@example.com",
                     user_email = "jon@example.com",
                     user_name = "Jon Smith",
                     asset_id = "asset-1",
                     zones = ["zone-1234", "zone-4567", "zone-890"],
                     booking_type = "desk",
                     booking_start = 5.minutes.from_now.to_unix,
                     booking_end = 1.hour.from_now.to_unix,
                     booked_by_email = "jon@example.com",
                     booked_by_id = "jon@example.com",
                     booked_by_name = "Jon Smith")
    Booking.create!(
      tenant_id: tenant_id,
      user_id: user_id,
      user_email: user_email,
      user_name: user_name,
      asset_id: asset_id,
      zones: zones,
      booking_type: booking_type,
      booking_start: booking_start,
      booking_end: booking_end,
      checked_in: false,
      approved: false,
      rejected: false,
      booked_by_email: booked_by_email,
      booked_by_id: booked_by_id,
      booked_by_name: booked_by_name,
    )
  end
end
