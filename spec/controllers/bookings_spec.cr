require "../spec_helper"
require "./helpers/spec_clean_up"

describe Bookings do
  describe "#index" do
    it "should return a list of bookings" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }

      booking1 = BookingsHelper.create_booking(tenant.id)
      booking2 = BookingsHelper.create_booking(tenant.id)

      starting = 5.minutes.from_now.to_unix
      ending = 90.minutes.from_now.to_unix
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&user=#{booking1.user_email}&type=desk"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)

      # filter by zones
      zones1 = booking1.zones.not_nil!
      zones_string = "#{zones1.first},#{booking2.zones.not_nil!.last}"
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zones_string}"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(2)

      # More filters by zones
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zones1.first}"
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
      guest_email = Faker::Internet.email

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

      guest_email = Faker::Internet.email
      ext_data = Faker::Lorem.word
      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"desk_1","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}","other":"#{ext_data}"}}), headers: Mock::Headers.office365_guest, &.create)
      Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"desk_2","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}"}}), headers: Mock::Headers.office365_guest, &.create)
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&extension_data={booking_for:#{guest_email},other:#{ext_data}}"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)
    end

    it "should return a list of bookings when filtered by user" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }

      booking1 = BookingsHelper.create_booking(tenant.id, "toby@redant.com.au")
      booking2 = BookingsHelper.create_booking(tenant.id)

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix

      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=current"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq([booking1.user_id])

      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=#{booking2.user_email}"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq([booking2.user_id])
    end

    it "should return a list of bookings filtered current user when no zones or user is specified" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      booking = BookingsHelper.create_booking(tenant_id: tenant.id, user_email: "toby@redant.com.au")
      BookingsHelper.create_booking(tenant.id)

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      # Since we are using Toby's token to login, user=current means Toby
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
      body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq([booking.user_id])
    end
  end

  it "#show should find booking" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["user_id"].should eq(booking.user_id)
    body["zones"].should eq(booking.zones)
  end

  it "#show should include the current state" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }

    booking = BookingsHelper.create_booking(tenant.id)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("reserved")

    booking = BookingsHelper.create_booking(tenant.id,
      booking_start: 5.minutes.ago.to_unix,
      booking_end: 1.hour.from_now.to_unix)

    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("checked_in")

    booking = BookingsHelper.create_booking(tenant.id,
      booking_start: 5.minutes.ago.to_unix,
      booking_end: 1.hour.from_now.to_unix)
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("checked_out")

    booking = BookingsHelper.create_booking(tenant.id,
      booking_start: 45.minutes.ago.to_unix,
      booking_end: 5.minutes.ago.to_unix)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("no_show")

    booking = BookingsHelper.create_booking(tenant.id)
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/reject", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.reject)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("rejected")

    booking = BookingsHelper.create_booking(tenant.id)
    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("cancelled")

    booking = BookingsHelper.create_booking(tenant.id,
      booking_start: 20.minutes.ago.to_unix,
      booking_end: 5.minutes.ago.to_unix)
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("ended")
  end

  it "#show should include history of state changes" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }

    Timecop.scale(600) # 1 second == 10 minutes

    booking = BookingsHelper.create_booking(tenant.id,
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 15.minutes.from_now.to_unix)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["history"][0]["state"].should eq("reserved")

    sleep(200.milliseconds) # advance time 2 minutes

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)[1].as_h
    body["history"].as_a.last["state"].should eq("checked_in")
    body["history"].as_a.size.should eq(2)

    sleep(500.milliseconds) # advance time 5 minutes

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)[1].as_h
    body["history"].as_a.last["state"].should eq("checked_out")
    body["history"].as_a.size.should eq(3)

    booking = BookingsHelper.create_booking(tenant.id,
      booking_start: 5.minutes.from_now.to_unix,
      booking_end: 25.minutes.from_now.to_unix)
    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/reject", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.reject)[1].as_h
    body["history"].as_a.last["state"].should eq("rejected")
    body["history"].as_a.size.should eq(2)

    booking = BookingsHelper.create_booking(tenant.id,
      booking_start: 5.minutes.from_now.to_unix,
      booking_end: 25.minutes.from_now.to_unix)
    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["history"].as_a.last["state"].should eq("cancelled")
    body["history"].as_a.size.should eq(2)
  end

  it "?utm_source= should set booked_from if it is not set" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    body = BookingsHelper.http_create_booking(
      asset_id: "desk1",
      booking_type: "desk",
      utm_source: "desktop",
      department: "accounting")[1].as_h
    body["booked_from"].should eq("desktop")
    body["department"].should eq("accounting")
  end

  it "?utm_source= should set source in history" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    Timecop.scale(600) # 1 second == 10 minutes

    body = BookingsHelper.http_create_booking(
      asset_id: "desk1",
      booking_type: "desk",
      booking_start: 2.minutes.from_now.to_unix,
      booking_end: 10.minutes.from_now.to_unix,
      utm_source: "desktop")[1].as_h
    body["history"].as_a.first["source"].should eq("desktop")

    sleep(300.milliseconds) # advance time 3 minutes

    booking_id = body["id"].to_s
    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking_id}/check_in?state=true&utm_source=mobile", route_params: {"id" => booking_id}, headers: Mock::Headers.office365_guest, &.check_in)[1].as_h
    body["history"].as_a.last["source"].should eq("mobile")

    sleep(500.milliseconds) # advance time 5 minutes

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking_id}/check_in?state=false&utm_source=kiosk", route_params: {"id" => booking_id}, headers: Mock::Headers.office365_guest, &.check_in)[1].as_h
    body["history"].as_a.last["source"].should eq("kiosk")

    body = BookingsHelper.http_create_booking(
      asset_id: "desk2",
      booking_type: "desk",
      utm_source: "desktop")[1].as_h
    booking_id = body["id"].to_s
    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking_id}/reject?utm_source=mobile", route_params: {"id" => booking_id}, headers: Mock::Headers.office365_guest, &.reject)[1].as_h
    body["history"].as_a.last["source"].should eq("mobile")

    body = BookingsHelper.http_create_booking(
      asset_id: "desk3",
      booking_type: "desk",
      utm_source: "desktop")[1].as_h
    booking_id = body["id"].to_s
    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking_id}/?utm_source=kiosk", route_params: {"id" => booking_id}, headers: Mock::Headers.office365_guest, &.destroy)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking_id}", route_params: {"id" => booking_id}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["history"].as_a.last["source"].should eq("kiosk")
  end

  it "#guest_list should list guests for a booking" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id)
    booking = BookingsHelper.create_booking(tenant.id)
    Attendee.create!({booking_id:     booking.id,
                      guest_id:       guest.id,
                      tenant_id:      guest.tenant_id,
                      checked_in:     false,
                      visit_expected: true,
    })

    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}/guests", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.guest_list)[1].as_a
    body.map(&.["name"]).should eq([guest.name])
  end

  it "#ensures case insensitivity in user emails" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking_name = Faker::Name.first_name
    booking_email = "#{booking_name.upcase}@email.com"

    booking = BookingsHelper.create_booking(tenant_id: tenant.id, user_email: booking_email)

    booking.user_id = booking_name.downcase
    booking.save!

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix

    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{booking_email.downcase}"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    booking_user_ids = body.map { |r| r["user_id"] }
    booking_user_ids.should eq([booking.user_id])

    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{booking_email}"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    booking_user_ids = body.map { |r| r["user_id"] }
    booking_user_ids.should eq([booking.user_id])
  end

  it "#destroy should delete a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }

    user_email = Faker::Internet.email
    booking1 = BookingsHelper.create_booking(tenant.id, user_email)
    booking2 = BookingsHelper.create_booking(tenant.id, user_email)

    # Check both are returned in beginning
    starting = [booking1.booking_start, booking2.booking_start].min
    ending = [booking1.booking_end, booking2.booking_end].max
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{user_email}"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(2)

    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking2.id}/", route_params: {"id" => booking2.id.to_s}, headers: Mock::Headers.office365_guest, &.destroy)

    # Check only one is returned after deletion
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{user_email}"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(1)
  end

  it "#destroy should not change the state of a checked in booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }

    Timecop.scale(600) # 1 second == 10 minutes

    booking = BookingsHelper.create_booking(tenant.id)
    booking.booking_start = 1.minutes.from_now.to_unix
    booking.save!

    sleep(200.milliseconds) # advance time 2 minutes
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)
    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("checked_in")
    body["history"].as_a.last["state"].should eq("checked_in")
    body["history"].as_a.size.should eq(2)
  end

  it "#destroy should not change the state of a checked out booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }

    Timecop.scale(600) # 1 second == 10 minutes

    booking = BookingsHelper.create_booking(tenant.id)
    booking.booking_start = 1.minutes.from_now.to_unix
    booking.booking_end = 15.minutes.from_now.to_unix
    booking.save!

    sleep(200.milliseconds) # advance time 2 minutes
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)
    sleep(400.milliseconds) # advance time 4 minutes
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.check_in)
    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking.id}/", route_params: {"id" => booking.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)
    body = Context(Bookings, JSON::Any).response("GET", "#{BOOKINGS_BASE}/#{booking.id}", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
    body["current_state"].should eq("checked_out")
    body["history"].as_a.last["state"].should eq("checked_out")
    body["history"].as_a.size.should eq(3)
  end

  it "#true query param should return deleted bookings" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    user_email = Faker::Internet.email
    booking1 = BookingsHelper.create_booking(tenant.id, user_email)
    booking2 = BookingsHelper.create_booking(tenant.id, user_email)

    # Check both are returned in beginning
    starting = [booking1.booking_start, booking2.booking_start].min
    ending = [booking1.booking_end, booking2.booking_end].max
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{user_email}"

    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{user_email}"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(2)

    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking1.id}/", route_params: {"id" => booking1.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)

    # Return one deleted booking
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&deleted=true&email=#{user_email}"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(1)
    body.first["id"].should eq(booking1.id)

    Context(Bookings, JSON::Any).delete_response("DELETE", "#{BOOKINGS_BASE}/#{booking2.id}/", route_params: {"id" => booking2.id.not_nil!.to_s}, headers: Mock::Headers.office365_guest, &.destroy)

    # Return both deleted bookings
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&deleted=true&email=#{user_email}"
    body = Context(Bookings, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a
    body.size.should eq(2)
    booking_user_ids = body.map { |r| r["id"].as_i }
    # Sorting ids because both events have the same starting time
    booking_user_ids.sort.should eq([booking1.id, booking2.id].sort)
  end

  it "#create and #update" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    user_name = Faker::Internet.user_name
    user_email = Faker::Internet.email
    starting = Random.new.rand(5..19).minutes.from_now.to_unix
    ending = Random.new.rand(25..39).minutes.from_now.to_unix

    created = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/", body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","booking_attendees": [
      {
          "name": "#{user_name}",
          "email": "#{user_email}",
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
    guest.name.should eq(user_name)
    guest.email.should eq(user_email)

    updated_user_name = Faker::Internet.user_name
    updated_user_email = Faker::Internet.email

    # instantiate the controller
    updated = Context(Bookings, JSON::Any).response("PATCH", "#{BOOKINGS_BASE}/#{created["id"]}", route_params: {"id" => created["id"].to_s}, body: %({"title":"new title","extension_data":{"other":"stuff"},"booking_attendees": [
      {
        "name": "#{updated_user_name}",
        "email": "#{updated_user_email}",
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
    guest.name.should eq(updated_user_name)
    guest.email.should eq(updated_user_email)
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

  it "#create and #update should not allow setting the history" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    booking = BookingsHelper.http_create_booking(
      booking_start: 5.minutes.from_now.to_unix,
      booking_end: 15.minutes.from_now.to_unix,
      history: [
        Booking::History.new(Booking::State::Reserved, Time.local.to_unix),
        Booking::History.new(Booking::State::CheckedIn, 6.minutes.from_now.to_unix),
        Booking::History.new(Booking::State::CheckedOut, 11.minutes.from_now.to_unix),
      ])[1].as_h
    booking["history"].as_a.size.should eq(1)

    updated = Context(Bookings, JSON::Any).response("PATCH", "#{BOOKINGS_BASE}/#{booking["id"]}",
      route_params: {"id" => booking["id"].to_s},
      body: {
        booking_start: 1.minutes.from_now.to_unix,
        booking_end:   11.minutes.from_now.to_unix,
        history:       [
          Booking::History.new(Booking::State::Reserved, Time.local.to_unix),
          Booking::History.new(Booking::State::Cancelled, Time.local.to_unix),
        ],
      }.to_json,
      headers: Mock::Headers.office365_guest, &.update)[1].as_h
    updated["history"].as_a.size.should eq(1)
  end

  it "#prevents a booking being saved with an end time before the start time" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    expect_raises(Clear::Model::InvalidError) do
      booking = BookingsHelper.create_booking(tenant_id: tenant.id)
      booking.booking_end = booking.booking_start - 2
      booking.save!
    end
  end

  it "#prevents a booking being saved with an end time the same as the start time" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    expect_raises(Clear::Model::InvalidError) do
      booking = BookingsHelper.create_booking(tenant_id: tenant.id)
      booking.booking_end = booking.booking_start
      booking.save!
    end
  end

  it "#approve & #reject" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(tenant.id)

    body = Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{booking.id}/approve", route_params: {"id" => booking.id.to_s}, headers: Mock::Headers.office365_guest, &.approve)[1].as_h
    booking = Booking.query.find! { user_id == booking.user_id }
    body["approved"].should eq(true)
    body["approver_id"].should eq(booking.approver_id)
    body["approver_email"].should eq(booking.approver_email)
    body["approver_name"].should eq(booking.approver_name)
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

  def create_booking(tenant_id, user_email)
    user_name = Faker::Internet.user_name
    zones = ["zone-#{Random.new.rand(500)}", "zone-#{Random.new.rand(500)}", "zone-#{Random.new.rand(500)}"]
    Booking.create!(
      tenant_id: tenant_id,
      user_id: user_email,
      user_email: PlaceOS::Model::Email.new(user_email),
      user_name: user_name,
      asset_id: "asset-#{Random.new.rand(500)}",
      zones: zones,
      booking_type: "desk",
      booking_start: Random.new.rand(5..19).minutes.from_now.to_unix,
      booking_end: Random.new.rand(25..79).minutes.from_now.to_unix,
      checked_in: false,
      approved: false,
      rejected: false,
      booked_by_email: PlaceOS::Model::Email.new(user_email),
      booked_by_id: user_email,
      booked_by_name: user_name,
      utm_source: "desktop",
      history: [] of Booking::History,
    )
  end

  def create_booking(tenant_id, booking_start, booking_end)
    booking = create_booking(tenant_id)
    booking.booking_start = booking_start
    booking.booking_end = booking_end
    booking.save!
  end

  def create_booking(tenant_id)
    user_email = Faker::Internet.email
    create_booking(tenant_id: tenant_id, user_email: user_email)
  end

  def http_create_booking(
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
    booked_by_name = "Jon Smith",
    history = nil,
    utm_source = nil,
    department = nil
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
      history:         history,
      department:      department,
    }.to_h.compact!.to_json

    param = utm_source ? "?utm_source=#{utm_source}" : ""
    Context(Bookings, JSON::Any).response("POST", "#{BOOKINGS_BASE}/#{param}",
      body: body,
      headers: Mock::Headers.office365_guest, &.create)
  end
end
