require "../spec_helper"

describe Bookings do
  Spec.after_each do
    Booking.query.each { |record| record.delete }
  end

  it "#index should return a list of bookings" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    BookingsHelper.create_booking(tenant.id)
    BookingsHelper.create_booking(tenant_id: tenant.id,
      user_id: "bob@example.com",
      user_email: "bob@example.com",
      asset_id: "asset-2",
      zones: ["zone-4127", "zone-890"],
      booking_end: 30.minutes.from_now.to_unix)

    response = IO::Memory.new

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    route = "/api/staff/v1/bookings?period_start=#{starting}&period_end=#{ending}&type=desk"
    Bookings.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    results.as_a.size.should eq(2)

    # filter by zones
    response = IO::Memory.new
    route = "/api/staff/v1/bookings?period_start=#{starting}&period_end=#{ending}&type=desk&zones=zone-890,zone-4127"
    Bookings.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    results.as_a.size.should eq(1)

    # More filters by zones
    response = IO::Memory.new
    route = "/api/staff/v1/bookings?period_start=#{starting}&period_end=#{ending}&type=desk&zones=zone-890"
    Bookings.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    results.as_a.size.should eq(2)
  end

  it "#index should return a list of bookings when filtered by user" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    BookingsHelper.create_booking(tenant_id: tenant.id,
      user_id: "toby@redant.com.au")
    BookingsHelper.create_booking(tenant.id)

    response = IO::Memory.new

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix

    # Since we are using Toby's token to login, user=current means Toby
    route = "/api/staff/v1/bookings?period_start=#{starting}&period_end=#{ending}&type=desk&user=current"
    Bookings.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    booking_user_ids = results.as_a.map { |r| r["user_id"] }
    booking_user_ids.should eq(["toby@redant.com.au"])

    response = IO::Memory.new
    route = "/api/staff/v1/bookings?period_start=#{starting}&period_end=#{ending}&type=desk&user=jon@example.com"
    Bookings.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    booking_user_ids = results.as_a.map { |r| r["user_id"] }
    booking_user_ids.should eq(["jon@example.com"])
  end

  it "#show should find booking" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    response = IO::Memory.new
    context = context("GET", "/api/staff/v1/bookings/#{booking.id}", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => booking.id.to_s}
    Bookings.new(context).show

    results = extract_json(response)

    results.as_h["user_id"].should eq("jon@example.com")
    results.as_h["zones"].should eq(["zone-1234", "zone-4567", "zone-890"])
  end

  it "#destroy should delete a booking" do
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
    response = IO::Memory.new
    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    route = "/api/staff/v1/bookings?period_start=#{starting}&period_end=#{ending}&type=desk"
    Bookings.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index
    results = extract_json(response)
    results.as_a.size.should eq(2)

    context = context("DELETE", "/api/staff/v1/bookings/#{booking.id}/", OFFICE365_HEADERS)
    context.route_params = {"id" => booking.id.not_nil!.to_s}
    Bookings.new(context).destroy

    # Check only one is returned after deletion
    response = IO::Memory.new
    route = "/api/staff/v1/bookings?period_start=#{starting}&period_end=#{ending}&type=desk"
    Bookings.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    results.as_a.size.should eq(1)
  end

  it "#create should create and #update should update a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix

    body = IO::Memory.new
    body << %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk"})
    body.rewind
    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/bookings/", OFFICE365_HEADERS, body, response_io: response)
    Bookings.new(context).create

    created = extract_json(response).as_h
    created["asset_id"].should eq("some_desk")
    created["booking_start"].should eq(starting)
    created["booking_end"].should eq(ending)

    # instantiate the controller
    body = IO::Memory.new
    body << %({"extension_data":{"other":"stuff"}})
    body.rewind
    response = IO::Memory.new
    context = context("PATCH", "/api/staff/v1/bookings/#{created["id"]}", OFFICE365_HEADERS, body, response_io: response)
    context.route_params = {"id" => created["id"].to_s}
    Bookings.new(context).update

    updated = extract_json(response).as_h
    updated["extension_data"].as_h["other"].should eq("stuff")
    booking = Booking.query.find({id: updated["id"]}).not_nil!
    booking.ext_data.not_nil!.as_h.should eq({"other" => "stuff"})
  end

  it "#approve should approve a booking and #reject should reject meeting" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")

    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/bookings/#{booking.id}/approve", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => booking.id.to_s}
    Bookings.new(context).approve

    results = extract_json(response)

    results.as_h["approved"].should eq(true)
    results.as_h["approver_id"].should eq("toby@redant.com.au")
    results.as_h["approver_email"].should eq("dev@acaprojects.com")
    results.as_h["approver_name"].should eq("Toby Carvan")
    results.as_h["rejected"].should eq(false)

    # Test rejection
    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/bookings/#{booking.id}/reject", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => booking.id.to_s}
    Bookings.new(context).reject

    results = extract_json(response)

    results.as_h["rejected"].should eq(true)
    results.as_h["approved"].should eq(false)
    # Reset approver info
    results.as_h["approver_id"].should eq(nil)
    results.as_h["approver_email"].should eq(nil)
    results.as_h["approver_name"].should eq(nil)
  end

  it "#check_in should set checked_in state of a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")

    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/bookings/#{booking.id}/check_in?state=true", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => booking.id.to_s}
    Bookings.new(context).check_in

    results = extract_json(response)

    results.as_h["checked_in"].should eq(true)

    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/bookings/#{booking.id}/check_in?state=false", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => booking.id.to_s}
    Bookings.new(context).check_in

    results = extract_json(response)

    results.as_h["checked_in"].should eq(false)
  end
end

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
                     booking_end = 1.hour.from_now.to_unix)
    booking = Booking.new
    booking.tenant_id = tenant_id
    booking.user_id = user_id
    booking.user_email = user_email
    booking.user_name = user_name
    booking.asset_id = asset_id
    booking.zones = zones
    booking.booking_type = booking_type
    booking.booking_start = booking_start
    booking.booking_end = booking_end
    booking.checked_in = false
    booking.approved = false
    booking.rejected = false
    booking.save!
  end
end
