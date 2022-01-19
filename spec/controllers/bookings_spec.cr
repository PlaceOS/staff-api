require "../spec_helper"
require "./helpers/spec_clean_up"

describe Bookings do
  describe "#index" do
    it "should return a list of bookings" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      BookingsHelper.create_booking(tenant.id)
      BookingsHelper.create_booking(tenant_id: tenant.id,
        user_id: "bob@example.com",
        user_email: "bob@example.com",
        asset_id: "asset-2",
        zones: ["zone-4127", "zone-890"],
        booking_end: 30.minutes.from_now.to_unix)

      starting = 5.minutes.from_now.to_unix
      ending = 90.minutes.from_now.to_unix
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&user=jon@example.com&type=desk"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)

      # filter by zones
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=zone-890,zone-4127"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(2)

      # More filters by zones
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=zone-4127"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)
    end

    it "should filter by ext data" do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      guest_email = "guest@email.com"

      Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"fsd_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}"}}), headers: Mock::Headers.office365_guest, &.create)
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&extension_data={booking_for:#{guest_email}}"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)
    end

    it "should filter by multiple ext data" do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")

      guest_email = "guest2@email.com"
      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"desk_1","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}","other":"stuff"}}), headers: Mock::Headers.office365_guest, &.create)
      Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"desk_2","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}"}}), headers: Mock::Headers.office365_guest, &.create)
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&extension_data={booking_for:#{guest_email},other:stuff}"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)
    end

    it "should return a list of bookings when filtered by user" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      BookingsHelper.create_booking(tenant_id: tenant.id, user_id: "toby@redant.com.au")
      BookingsHelper.create_booking(tenant.id)

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      # Since we are using Toby's token to login, user=current means Toby
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=current"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq(["toby@redant.com.au"])

      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=jon@example.com"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq(["jon@example.com"])
    end
  end

  it "#show should find booking" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["user_id"].should eq("jon@example.com")
    body["zones"].should eq(["zone-1234", "zone-4567", "zone-890"])
  end

  it "#guest_list should list guests for a booking" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
    booking = BookingsHelper.create_booking(tenant.id)
    Attendee.create!({booking_id:     booking.id,
                      guest_id:       guest.id,
                      tenant_id:      guest.tenant_id,
                      checked_in:     false,
                      visit_expected: true,
    })

    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}/guests", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.guest_list)[1].as_a
    body.map(&.["name"]).should eq(["Jon"])
  end

  it "#ensures case insensitivity in user emails" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    BookingsHelper.create_booking(tenant_id: tenant.id, user_id: "dave", user_email: "DAVE@example.com", booked_by_email: "toby@redant.com.au")

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix

    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=dave@example.com"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    booking_user_ids = body.map { |r| r["user_id"] }
    booking_user_ids.should eq(["dave"])

    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=DAVE@example.com"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    booking_user_ids = body.map { |r| r["user_id"] }
    booking_user_ids.should eq(["dave"])
  end

  it "#destroy should delete a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    BookingsHelper.create_booking(
      tenant.id, user_id: "toby@redant.com.au",
      user_email: "toby@redant.com.au")
    booking = BookingsHelper.create_booking(tenant_id: tenant.id,
      user_id: "toby@redant.com.au",
      user_email: "toby@redant.com.au",
      asset_id: "asset-2",
      zones: ["zone-4127", "zone-890"],
      booking_end: 30.minutes.from_now.to_unix)

    # Check both are returned in beginning
    starting = 5.minutes.from_now.to_unix
    ending = 80.minutes.from_now.to_unix
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(2)

    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)

    # Check only one is returned after deletion
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(1)
  end

  it "#true query param should return deleted bookings" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking1 = BookingsHelper.create_booking(
      tenant.id, user_id: "toby@redant.com.au",
      user_email: "toby@redant.com.au")
    booking2 = booking = BookingsHelper.create_booking(tenant_id: tenant.id,
      user_id: "toby@redant.com.au",
      user_email: "toby@redant.com.au",
      asset_id: "asset-2",
      zones: ["zone-4127", "zone-890"],
      booking_end: 30.minutes.from_now.to_unix)

    # Check both are returned in beginning
    starting = 5.minutes.from_now.to_unix
    ending = 80.minutes.from_now.to_unix
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(2)

    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking1.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)

    # Return one deleted booking
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&deleted=true"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(1)
    body.first["id"].should eq(booking1.id)

    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking2.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)

    # Return both deleted bookings
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&deleted=true"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(2)
    booking_user_ids = body.map { |r| r["id"] }
    booking_user_ids.should eq([booking1.id, booking2.id])
  end

  it "#create should create and #update should update a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    created = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","booking_attendees": [
      {
          "name": "test",
          "email": "test@example.com",
          "checked_in": true,
          "visit_expected": true
      }]}), headers: Mock::Headers.office365_guest, &.create)[1].as_h
    created["asset_id"].should eq("some_desk")
    created["booking_start"].should eq(starting)
    created["booking_end"].should eq(ending)

    # Testing attendees / guests data creation
    attendees = Booking.query.find! { id == created["id"] }.attendees.to_a
    attendees.size.should eq(1)
    attendee = attendees.first
    attendee.checked_in.should eq(true)
    attendee.visit_expected.should eq(true)

    guest = attendee.guest
    guest.name.should eq("test")
    guest.email.should eq("test@example.com")

    # instantiate the controller
    updated = Context(Bookings, JSON::Any).response("PATCH", "#{BOOKINGS_BASE}/#{created["id"]}", route_params: {"id" => created["id"].to_s}, body: %({"title":"new title","extension_data":{"other":"stuff"},"booking_attendees": [
      {
          "name": "jon",
          "email": "jon@example.com",
          "checked_in": false,
          "visit_expected": true
      }]}), headers: Mock::Headers.office365_guest, &.update)[1].as_h
    updated["extension_data"].as_h["other"].should eq("stuff")
    booking = Booking.query.find!({id: updated["id"]})
    booking.extension_data.as_h.should eq({"other" => "stuff"})
    updated["title"].should eq("new title")
    booking = Booking.query.find!(updated["id"])
    booking.title.not_nil!.should eq("new title")

    # Testing attendees / guests data updates
    attendees = Booking.query.find! { id == updated["id"] }.attendees.to_a
    attendees.size.should eq(1)
    attendee = attendees.first
    attendee.checked_in.should eq(false)
    attendee.visit_expected.should eq(true)

    guest = attendee.guest
    guest.name.should eq("jon")
    guest.email.should eq("jon@example.com")
  end

  # add support for configurable booking limits on resources
  it "#create and #update should respect booking limits" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    # Set booking limit
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    tenant.booking_limits = JSON.parse(%({"desk": 2}))
    tenant.save!

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    common = {
      booking_start: 5.minutes.from_now.to_unix,
      booking_end:   40.minutes.from_now.to_unix,
      booking_type:  "desk",
    }
    different_starting = 45.minutes.from_now.to_unix
    different_ending = 55.minutes.from_now.to_unix

    first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1].as_h
    first_booking["asset_id"].should eq("first_desk")

    second_booking = BookingsHelper.http_create_booking(**common, asset_id: "second_desk")[1].as_h
    second_booking["asset_id"].should eq("second_desk")

    # Fail to create booking due to limit
    not_created = BookingsHelper.http_create_booking(**common, asset_id: "third_desk")[0]
    not_created.should eq(409)

    # Create third booking at a different time
    third_booking = BookingsHelper.http_create_booking(
      booking_start: different_starting,
      booking_end: different_ending,
      booking_type: "desk",
      asset_id: "third_desk")[1].as_h
    third_booking["asset_id"].should eq("third_desk")

    # Fail to change booking due to limit
    not_updated = Context(Bookings, JSON::Any).response("PATCH", "#{BOOKINGS_BASE}/#{third_booking["id"]}",
      route_params: {"id" => third_booking["id"].to_s},
      body: %({"booking_start":#{starting},"booking_end":#{ending}}),
      headers: Mock::Headers.office365_guest, &.update)[0]
    not_updated.should eq(409)
  end

  it "#update limit check can't clash with itself when updating a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    # Set booking limit
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    tenant.booking_limits = JSON.parse(%({"desk": 2}))
    tenant.save!

    common = {
      booking_start: 5.minutes.from_now.to_unix,
      booking_end:   40.minutes.from_now.to_unix,
      booking_type:  "desk",
    }
    different_starting = 20.minutes.from_now.to_unix
    different_ending = 60.minutes.from_now.to_unix

    first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1].as_h
    first_booking["asset_id"].should eq("first_desk")

    second_booking = BookingsHelper.http_create_booking(**common, asset_id: "second_desk")[1].as_h
    second_booking["asset_id"].should eq("second_desk")

    updated = Context(Bookings, JSON::Any).response("PATCH", "#{BOOKINGS_BASE}/#{second_booking["id"]}",
      route_params: {"id" => second_booking["id"].to_s},
      body: %({"booking_start":#{different_starting},"booking_end":#{different_ending}}),
      headers: Mock::Headers.office365_guest, &.update)[1].as_h
    updated["booking_start"].should eq(different_starting)
    updated["booking_end"].should eq(different_ending)
  end

  it "#create and #update should respect booking limits when booking on behalf of other users" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    # Set booking limit
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    tenant.booking_limits = JSON.parse(%({"desk": 2}))
    tenant.save!

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    different_starting = 45.minutes.from_now.to_unix
    different_ending = 55.minutes.from_now.to_unix

    common = {
      booking_start: starting,
      booking_end:   ending,
      booking_type:  "desk",
      user_id:       "bob@example.com",
      user_email:    "bob@example.com",
    }

    first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1].as_h
    first_booking["asset_id"].should eq("first_desk")

    second_booking = BookingsHelper.http_create_booking(**common, asset_id: "second_desk")[1].as_h
    second_booking["asset_id"].should eq("second_desk")

    # Fail to create booking due to limit
    not_created = BookingsHelper.http_create_booking(**common, asset_id: "third_desk")[0]
    not_created.should eq(409)

    # Create third booking at a different time
    third_booking = BookingsHelper.http_create_booking(
      booking_start: different_starting,
      booking_end: different_ending,
      booking_type: "desk",
      user_id: "bob@example.com",
      user_email: "bob@example.com",
      asset_id: "third_desk")[1].as_h
    third_booking["asset_id"].should eq("third_desk")

    # Fail to change booking due to limit
    not_updated = Context(Bookings, JSON::Any).response("PATCH", "#{BOOKINGS_BASE}/#{third_booking["id"]}",
      route_params: {"id" => third_booking["id"].to_s},
      body: %({"booking_start":#{starting}, "booking_end":#{ending}}),
      headers: Mock::Headers.office365_guest, &.update)[0]
    not_updated.should eq(409)
  end

  it "#prevents a booking being saved with an end time before the start time" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    expect_raises(Clear::Model::InvalidError) do
      BookingsHelper.create_booking(tenant_id: tenant.id, booking_start: 5.minutes.from_now.to_unix,
        booking_end: 3.minutes.from_now.to_unix)
    end
  end

  it "#prevents a booking being saved with an end time the same as the start time" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    expect_raises(Clear::Model::InvalidError) do
      BookingsHelper.create_booking(tenant_id: tenant.id, booking_start: 5.minutes.from_now.to_unix,
        booking_end: 5.minutes.from_now.to_unix)
    end
  end

  it "#approve should approve a booking and #reject should reject meeting" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/approve", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.approve)[1].as_h
    body["approved"].should eq(true)
    body["approver_id"].should eq("toby@redant.com.au")
    body["approver_email"].should eq("dev@acaprojects.com")
    body["approver_name"].should eq("Toby Carvan")
    body["rejected"].should eq(false)

    # Test rejection
    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/reject", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.reject)[1].as_h
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

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)[1].as_h
    body["checked_in"].should eq(true)

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)[1].as_h
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
      user_email: PlaceOS::Model::Email.new(user_email),
      user_name: user_name,
      asset_id: asset_id,
      zones: zones,
      booking_type: booking_type,
      booking_start: booking_start,
      booking_end: booking_end,
      checked_in: false,
      approved: false,
      rejected: false,
      booked_by_email: PlaceOS::Model::Email.new(booked_by_email),
      booked_by_id: booked_by_id,
      booked_by_name: booked_by_name,
    )
  end

  def http_create_booking(
    user_id = nil,
    user_email = nil,
    user_name = nil,
    asset_id = nil,
    zones = nil,
    booking_type = nil,
    booking_start = 5.minutes.from_now.to_unix,
    booking_end = 1.hour.from_now.to_unix,
    booked_by_email = nil,
    booked_by_id = nil,
    booked_by_name = nil
  )
    body = {
      user_id:         user_id,
      user_email:      user_email ? PlaceOS::Model::Email.new(user_email) : nil,
      user_name:       user_name,
      asset_id:        asset_id,
      zones:           zones,
      booking_type:    booking_type,
      booking_start:   booking_start,
      booking_end:     booking_end,
      booked_by_email: booked_by_email ? PlaceOS::Model::Email.new(booked_by_email) : nil,
      booked_by_id:    booked_by_id,
      booked_by_name:  booked_by_name,
    }.to_h.compact!.to_json

    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/",
      body: body,
      headers: Mock::Headers.office365_guest, &.create)
  end
end
