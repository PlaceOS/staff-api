require "../spec_helper"
require "./helpers/booking_helper"
require "./helpers/guest_helper"

describe Bookings do
  Spec.before_each {
    Booking.truncate
    Attendee.truncate
    Guest.truncate
  }

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of bookings" do
      tenant = get_tenant

      booking1 = BookingsHelper.create_booking(tenant.id.not_nil!)
      booking2 = BookingsHelper.create_booking(tenant.id.not_nil!)

      starting = 5.minutes.from_now.to_unix
      ending = 90.minutes.from_now.to_unix
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&user=#{booking1.user_email}&type=desk"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      body.size.should eq(1)

      # filter by zones
      zones1 = booking1.zones.not_nil!
      zones_string = "#{zones1.first},#{booking2.zones.not_nil!.last}"
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zones_string}"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      body.size.should eq(2)

      # More filters by zones
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zones1.first}"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      body.size.should eq(1)
    end

    it "should return linked event" do
      tenant = get_tenant
      event = EventMetadatasHelper.create_event(tenant.id)
      booking1 = BookingsHelper.create_booking(tenant.id.not_nil!, event_id: event.id)

      starting = 5.minutes.from_now.to_unix
      ending = 90.minutes.from_now.to_unix
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&user=#{booking1.user_email}&type=desk"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      body.size.should eq(1)

      body.includes?("linked_event")
      body.first["linked_event"]["event_id"].as_s.should eq event.event_id
    end

    it "should filter by ext data" do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      guest_email = Faker::Internet.email

      client.post(BOOKINGS_BASE, headers: headers, body: %({"asset_id":"fsd_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}"}}))
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&extension_data={booking_for:#{guest_email}}"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
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
      client.post(BOOKINGS_BASE, headers: headers, body: %({"asset_id":"desk_1","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}","other":"#{ext_data}"}}))
      client.post(BOOKINGS_BASE, headers: headers, body: %({"asset_id":"desk_2","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"booking_for":"#{guest_email}"}}))
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&extension_data={booking_for:#{guest_email},other:#{ext_data}}"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      body.size.should eq(1)
    end

    it "should return a list of bookings when filtered by user" do
      tenant = get_tenant

      booking1 = BookingsHelper.create_booking(tenant.id.not_nil!, "toby@redant.com.au")
      booking2 = BookingsHelper.create_booking(tenant.id.not_nil!)

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix

      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=current"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq([booking1.user_id])

      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&user=#{booking2.user_email}"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq([booking2.user_id])
    end

    it "should return a list of bookings filtered current user when no zones or user is specified" do
      tenant = get_tenant
      booking = BookingsHelper.create_booking(tenant_id: tenant.id.not_nil!, user_email: "toby@redant.com.au")
      BookingsHelper.create_booking(tenant.id.not_nil!)

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      # Since we are using Toby's token to login, user=current means Toby
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk"
      body = JSON.parse(client.get(route, headers: headers).body).as_a
      booking_user_ids = body.map { |r| r["user_id"] }
      booking_user_ids.should eq([booking.user_id])
    end
  end

  it "should include bookins made on behalf of other users when include_booked_by=true" do
    tenant = get_tenant
    booking1 = BookingsHelper.create_booking(tenant_id: tenant.id.not_nil!, user_email: "toby@redant.com.au")

    booked_by_email = "josh@redant.com.au"
    booking2 = BookingsHelper.create_booking(tenant_id: tenant.id.not_nil!, user_email: "toby@redant.com.au")
    booking2.booked_by_email = PlaceOS::Model::Email.new(booked_by_email)
    booking2.booked_by_id = booked_by_email
    booking2.booked_by_name = Faker::Internet.user_name
    booking2.save!

    booking3 = BookingsHelper.create_booking(tenant_id: tenant.id.not_nil!, user_email: booked_by_email)

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix

    route = "#{BOOKINGS_BASE}?type=desk&period_start=#{starting}&period_end=#{ending}&user=#{booked_by_email}&include_booked_by=true&include_checked_out=true"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    booking_ids = body.map { |r| r["id"] }
    booking_ids.should_not contain(booking1.id)
    booking_ids.should contain(booking2.id)
    booking_ids.should contain(booking3.id)
  end

  it "#show should find booking" do
    tenant = get_tenant
    booking = BookingsHelper.create_booking(tenant.id.not_nil!)

    body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
    body["user_id"].should eq(booking.user_id)
    body["zones"].should eq(booking.zones)
  end

  describe "current_state and history:" do
    before_each do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")

      Timecop.scale(600) # 1 second == 10 minutes
    end

    after_all do
      WebMock.reset
    end

    it "booking reserved and no_show" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 6.minutes.from_now.to_unix)

      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h

      body["current_state"].should eq("reserved")
      body["history"][0]["state"].should eq("reserved")

      sleep(200.milliseconds) # advance time 2 minutes

      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("reserved")

      sleep(500.milliseconds) # advance time 5 minutes

      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("no_show")
    end

    it "booking deleted before booking_start" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      client.delete("#{BOOKINGS_BASE}/#{booking.id}", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h

      body["current_state"].should eq("cancelled")
      body["history"].as_a.last["state"].should eq("cancelled")
      body["history"].as_a.size.should eq(2)
    end

    it "booking deleted between booking_start and booking_end" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      sleep(200.milliseconds) # advance time 2 minutes

      client.delete("#{BOOKINGS_BASE}/#{booking.id}", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("no_show")
    end

    it "booking deleted between booking_start and booking_end while checked_in" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      sleep(200.milliseconds) # advance time 2 minutes

      # check in
      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in", headers: headers)

      sleep(200.milliseconds) # advance time 2 minutes

      client.delete("#{BOOKINGS_BASE}/#{booking.id}", headers: headers)
      body = JSON.parse client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body
      body["current_state"].should eq("cancelled")
      body["history"].as_a.last["state"].should eq("cancelled")
    end

    it "check in early less than an hour before booking start" do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")
      tenant = get_tenant

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 20.minutes.from_now.to_unix,
        booking_end: 30.minutes.from_now.to_unix)

      check_in_early = client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in", headers: headers).status_code
      check_in_early.should eq(200)
    end

    it "cannot check in early more than an hour before booking start" do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")
      tenant = get_tenant

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 70.minutes.from_now.to_unix,
        booking_end: 80.minutes.from_now.to_unix)

      check_in_early = client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in", headers: headers).status_code
      check_in_early.should eq(405)
    end

    it "cannot check in early when another booking is present" do
      Timecop.scale(1)

      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")
      tenant = get_tenant

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 20.minutes.from_now.to_unix,
        booking_end: 30.minutes.from_now.to_unix)

      BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 5.minutes.from_now.to_unix,
        booking_end: 10.minutes.from_now.to_unix,
        asset_id: booking.asset_id)

      check_in_early = client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in", headers: headers).status_code
      check_in_early.should eq(409)
    end

    it "cannot check in early on another day" do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")
      tenant = get_tenant

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: Time.utc(2023, 2, 15, 10, 20, 30).to_unix,
        booking_end: Time.utc(2023, 2, 15, 11, 20, 30).to_unix)

      check_in_early = client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in", headers: headers).status_code
      check_in_early.should eq(405)
    end

    it "booking rejected before booking_start" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      client.post("#{BOOKINGS_BASE}/#{booking.id}/reject", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("rejected")
      body["history"].as_a.last["state"].should eq("rejected")
      body["history"].as_a.size.should eq(2)
    end

    it "booking checked_in before booking_start" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("checked_in")
      body["history"].as_a.last["state"].should eq("checked_in")
      body["history"].as_a.size.should eq(2)
    end

    it "booking checked_in and checked_out before booking_start" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 5.minutes.from_now.to_unix,
        booking_end: 15.minutes.from_now.to_unix)

      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("checked_in")
      body["history"].as_a.last["state"].should eq("checked_in")
      body["history"].as_a.size.should eq(2)

      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("checked_out")
      body["history"].as_a.last["state"].should eq("checked_out")
      body["history"].as_a.size.should eq(3)
    end

    it "booking checked_in and checked_out between booking_start and booking_end" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      sleep(200.milliseconds) # advance time 2 minutes

      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("checked_in")
      body["history"].as_a.last["state"].should eq("checked_in")
      body["history"].as_a.size.should eq(2)

      sleep(500.milliseconds) # advance time 5 minutes

      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("checked_out")
      body["history"].as_a.last["state"].should eq("checked_out")
      body["history"].as_a.size.should eq(3)
    end

    it "booking checked_in but never checked_out between booking_start and booking_end" do
      tenant = Tenant.find_by(domain: "toby.staff-api.dev")

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 6.minutes.from_now.to_unix)

      sleep(200.milliseconds) # advance time 2 minutes

      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", headers: headers)

      sleep(500.milliseconds) # advance time 5 minutes

      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
      body["current_state"].should eq("ended")
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
        ])[1]
      booking["history"].as_a.size.should eq(1)

      updated = JSON.parse(client.patch("#{BOOKINGS_BASE}/#{booking["id"]}", headers: headers, body: {
        booking_start: 1.minutes.from_now.to_unix,
        booking_end:   11.minutes.from_now.to_unix,
        history:       [
          Booking::History.new(Booking::State::Reserved, Time.local.to_unix),
          Booking::History.new(Booking::State::Cancelled, Time.local.to_unix),
        ],
      }.to_json).body).as_h
      updated["history"].as_a.size.should eq(1)
    end
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
      department: "accounting")[1]
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
      utm_source: "desktop")[1]
    body["history"].as_a.first["source"].should eq("desktop")

    sleep(300.milliseconds) # advance time 3 minutes

    booking_id = body["id"].to_s
    body = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=true&utm_source=mobile", headers: headers).body).as_h
    body["history"].as_a.last["source"].should eq("mobile")

    sleep(500.milliseconds) # advance time 5 minutes

    body = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=false&utm_source=kiosk", headers: headers).body).as_h
    body["history"].as_a.last["source"].should eq("kiosk")

    body = BookingsHelper.http_create_booking(
      asset_id: "desk2",
      booking_type: "desk",
      utm_source: "desktop")[1]
    booking_id = body["id"].to_s
    body = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/reject?utm_source=mobile", headers: headers).body).as_h
    body["history"].as_a.last["source"].should eq("mobile")

    body = BookingsHelper.http_create_booking(
      asset_id: "desk3",
      booking_type: "desk",
      utm_source: "desktop")[1]
    booking_id = body["id"].to_s

    client.delete("#{BOOKINGS_BASE}/#{booking_id}/?utm_source=kiosk", headers: headers).status_code
    body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}", headers: headers).body).as_h
    body["history"].as_a.last["source"].should eq("kiosk")
  end

  it "#guest_list should list guests for a booking" do
    tenant = get_tenant
    guest = GuestsHelper.create_guest(tenant.id)
    booking = BookingsHelper.create_booking(tenant.id.not_nil!)
    Attendee.create!(booking_id: booking.id.not_nil!,
      guest_id: guest.id,
      tenant_id: guest.tenant_id,
      checked_in: false,
      visit_expected: true,
    )

    body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}/guests", headers: headers).body).as_a
    body.map(&.["name"]).should eq([guest.name])
  end

  it "#ensures case insensitivity in user emails" do
    tenant = get_tenant
    booking_name = Faker::Name.first_name
    booking_email = "#{booking_name.upcase}@email.com"

    booking = BookingsHelper.create_booking(tenant_id: tenant.id.not_nil!, user_email: booking_email)

    booking.user_id = booking_name.downcase
    booking.save!

    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix

    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{booking_email.downcase}"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    booking_user_ids = body.map { |r| r["user_id"] }
    booking_user_ids.should eq([booking.user_id])

    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{booking_email}"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    booking_user_ids = body.map { |r| r["user_id"] }
    booking_user_ids.should eq([booking.user_id])
  end

  it "#destroy should delete a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = get_tenant

    user_email = Faker::Internet.email
    booking1 = BookingsHelper.create_booking(tenant.id.not_nil!, user_email)
    booking2 = BookingsHelper.create_booking(tenant.id.not_nil!, user_email)

    # Check both are returned in beginning
    starting = [booking1.booking_start, booking2.booking_start].min
    ending = [booking1.booking_end, booking2.booking_end].max
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{user_email}"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    body.size.should eq(2)

    client.delete("#{BOOKINGS_BASE}/#{booking2.id}/", headers: headers)

    # Check only one is returned after deletion
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{user_email}"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    body.size.should eq(1)
  end

  it "#destroy should not change the state of a checked out booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = get_tenant

    Timecop.scale(600) # 1 second == 10 minutes

    booking = BookingsHelper.create_booking(tenant.id.not_nil!, booking_start: 1.minutes.from_now.to_unix, booking_end: 15.minutes.from_now.to_unix)

    sleep(200.milliseconds) # advance time 2 minutes
    client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", headers: headers)
    sleep(400.milliseconds) # advance time 4 minutes
    client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", headers: headers)
    client.delete("#{BOOKINGS_BASE}/#{booking.id}", headers: headers)
    body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}", headers: headers).body).as_h
    body["current_state"].should eq("checked_out")
    body["history"].as_a.last["state"].should eq("checked_out")
    body["history"].as_a.size.should eq(3)
  end

  it "#true query param should return deleted bookings" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = get_tenant
    user_email = Faker::Internet.email
    booking1 = BookingsHelper.create_booking(tenant.id.not_nil!, user_email)
    booking2 = BookingsHelper.create_booking(tenant.id.not_nil!, user_email)

    # Check both are returned in beginning
    starting = [booking1.booking_start, booking2.booking_start].min
    ending = [booking1.booking_end, booking2.booking_end].max
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&email=#{user_email}"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    body.size.should eq(2)

    client.delete("#{BOOKINGS_BASE}/#{booking1.id}", headers: headers)

    # Return one deleted booking
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&deleted=true&email=#{user_email}"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    body.size.should eq(1)
    body.first["id"].should eq(booking1.id)

    client.delete("#{BOOKINGS_BASE}/#{booking2.id}", headers: headers)

    # Return both deleted bookings
    route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&deleted=true&email=#{user_email}"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    body.size.should eq(2)
    booking_user_ids = body.map { |r| r["id"].as_i }
    # Sorting ids because both events have the same starting time
    booking_user_ids.sort.should eq([booking1.id.not_nil!, booking2.id.not_nil!].sort)
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

    created = JSON.parse(client.post(BOOKINGS_BASE, headers: headers,
      body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","attendees": [
      {
          "name": "#{user_name}",
          "email": "#{user_email}",
          "checked_in": true,
          "visit_expected": true
      }]})
    ).body)
    created["asset_id"].should eq("some_desk")
    created["booking_start"].should eq(starting)
    created["booking_end"].should eq(ending)

    # Testing attendees / guests data creation
    attendees = Booking.find(created["id"].as_i64).attendees.to_a
    attendees.size.should eq(1)
    attendee = attendees.first
    attendee.checked_in.should eq(true)
    attendee.visit_expected.should eq(true)

    guest = attendee.guest.not_nil!
    guest.name.should eq(user_name)
    guest.email.should eq(user_email)

    updated_user_name = Faker::Internet.user_name
    updated_user_email = Faker::Internet.email

    # instantiate the controller
    updated = JSON.parse(client.patch("#{BOOKINGS_BASE}/#{created["id"]}", headers: headers, body: %({"title":"new title","extension_data":{"other":"stuff"},"attendees": [
      {
        "name": "#{updated_user_name}",
        "email": "#{updated_user_email}",
          "checked_in": false,
          "visit_expected": true
      }]})
    ).body).as_h
    updated["extension_data"].as_h["other"].should eq("stuff")
    booking = Booking.find(updated["id"].as_i64)
    booking.extension_data.as_h.should eq({"other" => "stuff"})
    updated["title"].should eq("new title")
    booking = Booking.find(updated["id"].as_i64)
    booking.title.not_nil!.should eq("new title")

    # Testing attendees / guests data updates
    attendees = Booking.find(updated["id"].as_i64).attendees.to_a
    attendees.size.should eq(1)
    attendee = attendees.first
    attendee.checked_in.should eq(false)
    attendee.visit_expected.should eq(true)

    guest = attendee.guest.not_nil!
    guest.name.should eq(updated_user_name)
    guest.email.should eq(updated_user_email)
  end

  it "#cannot double book the same asset" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    user_name = Faker::Internet.user_name
    user_email = Faker::Internet.email

    starting = 5.minutes.from_now.to_unix
    ending = 20.minutes.from_now.to_unix

    created = client.post("#{BOOKINGS_BASE}/", headers: headers, body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","attendees": [
      {
          "name": "#{user_name}",
          "email": "#{user_email}",
          "checked_in": true,
          "visit_expected": true
      }]})
    ).status_code
    created.should eq(201)

    sleep 3

    client.post("#{BOOKINGS_BASE}/", headers: headers, body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","attendees": [
      {
          "name": "#{user_name}",
          "email": "#{user_email}",
          "checked_in": true,
          "visit_expected": true
      }]})
    ).status.should eq HTTP::Status::CONFLICT
  end

  describe "booking_limits" do
    before_all do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")

      Timecop.scale(600) # 1 second == 10 minutes
    end

    after_all do
      WebMock.reset
    end

    # add support for configurable booking limits on resources
    it "#create and #update should respect booking limits" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix
      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   40.minutes.from_now.to_unix,
        booking_type:  "desk",
        zones:         ["zone-1", "zone-2"],
      }
      different_starting = 45.minutes.from_now.to_unix
      different_ending = 55.minutes.from_now.to_unix

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      second_booking = BookingsHelper.http_create_booking(**common, asset_id: "second_desk")[1]
      second_booking["asset_id"].should eq("second_desk")

      # Fail to create booking due to limit
      BookingsHelper.http_create_booking(**common, asset_id: "third_desk")[0].should eq 410

      # Create third booking at a different time
      third_booking = BookingsHelper.http_create_booking(
        booking_start: different_starting,
        booking_end: different_ending,
        booking_type: "desk",
        asset_id: "third_desk",
        zones: ["zone-1", "zone-2"]
      )[1]
      third_booking["asset_id"].should eq("third_desk")

      # Create fourth booking in different zone
      common_zone4 = common.merge({zones: ["zone-4"]})
      fourth_booking = BookingsHelper.http_create_booking(**common_zone4, asset_id: "fourth_desk")[1]
      fourth_booking["asset_id"].should eq("fourth_desk")

      # Fail to change booking due to limit
      client.patch("#{BOOKINGS_BASE}/#{third_booking["id"]}",
        headers: headers,
        body: %({"booking_start":#{starting},"booking_end":#{ending}})
      ).status.should eq HTTP::Status::GONE
    end

    it "#create and #update should allow overriding booking limits" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 1}))
      tenant.save!

      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   40.minutes.from_now.to_unix,
        booking_type:  "desk",
      }

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      # Fail to create booking due to limit
      BookingsHelper.http_create_booking(**common, asset_id: "second_desk")[0].should eq 410

      # Create booking with limit_override=true
      second_booking = BookingsHelper.http_create_booking(
        **common,
        asset_id: "second_desk",
        limit_override: "2")[1]
      second_booking["asset_id"].should eq("second_desk")
    end

    it "#update limit check can't clash with itself when updating a booking" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   40.minutes.from_now.to_unix,
        booking_type:  "desk",
      }
      different_starting = 20.minutes.from_now.to_unix
      different_ending = 60.minutes.from_now.to_unix

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      second_booking = BookingsHelper.http_create_booking(**common, asset_id: "second_desk")[1]
      second_booking["asset_id"].should eq("second_desk")

      updated = JSON.parse(client.patch("#{BOOKINGS_BASE}/#{second_booking["id"]}",
        headers: headers,
        body: %({"booking_start":#{different_starting},"booking_end":#{different_ending}})
      ).body)
      updated["booking_start"].should eq(different_starting)
      updated["booking_end"].should eq(different_ending)
    end

    it "#create and #update should respect booking limits when booking on behalf of other users" do
      # Set booking limit
      tenant = get_tenant
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

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      second_booking = BookingsHelper.http_create_booking(**common, asset_id: "second_desk")[1]
      second_booking["asset_id"].should eq("second_desk")

      # Fail to create booking due to limit
      BookingsHelper.http_create_booking(**common, asset_id: "third_desk")[0].should eq 410

      # Create third booking at a different time
      third_booking = BookingsHelper.http_create_booking(
        booking_start: different_starting,
        booking_end: different_ending,
        booking_type: "desk",
        user_id: "bob@example.com",
        user_email: "bob@example.com",
        asset_id: "third_desk")[1]
      third_booking["asset_id"].should eq("third_desk")

      # Fail to change booking due to limit
      client.patch("#{BOOKINGS_BASE}/#{third_booking["id"]}",
        headers: headers,
        body: %({"booking_start":#{starting},"booking_end":#{ending}})
      ).status.should eq HTTP::Status::GONE
    end

    it "booking limit is not checked on checkout" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 1}))
      tenant.save!

      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   15.minutes.from_now.to_unix,
        booking_type:  "desk",
      }

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      # Create booking with limit_override=true
      second_booking = BookingsHelper.http_create_booking(
        **common,
        asset_id: "second_desk",
        limit_override: "2")[1]
      second_booking["asset_id"].should eq("second_desk")

      sleep(500.milliseconds) # advance time 5 minutes
      booking_id = first_booking["id"].to_s

      # check in
      checked_in = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=true", headers: headers).body)
      checked_in["checked_in"].should eq(true)

      sleep(500.milliseconds) # advance time 5 minutes

      # Check out (without limit_override)
      checked_out = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=false", headers: headers).body)
      checked_out["checked_in"].should eq(false)
    end

    it "booking limit is not checked on #destroy" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 1}))
      tenant.save!

      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   15.minutes.from_now.to_unix,
        booking_type:  "desk",
      }

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      # Create booking with limit_override=true
      second_booking = BookingsHelper.http_create_booking(
        **common,
        asset_id: "second_desk",
        limit_override: "2")[1]
      second_booking["asset_id"].should eq("second_desk")

      booking_id = first_booking["id"].as_i64

      # delete booking (without limit_override)
      deleted = client.delete("#{BOOKINGS_BASE}/#{booking_id}/", headers: headers).status_code
      deleted.should eq(202)

      # check that it was deleted
      Booking.find(booking_id).deleted.should be_true
    end

    it "#check_in only checks limit if checked out" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 1}))
      tenant.save!

      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   45.minutes.from_now.to_unix,
        booking_type:  "desk",
      }

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      # Create booking with limit_override=true
      second_booking = BookingsHelper.http_create_booking(
        **common,
        asset_id: "second_desk",
        limit_override: "2")[1]
      second_booking["asset_id"].should eq("second_desk")

      sleep(500.milliseconds) # advance time 5 minutes
      booking_id = first_booking["id"].to_s

      # check in
      checked_in = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=true", headers: headers).body).as_h
      checked_in["checked_in"].should eq(true)

      sleep(500.milliseconds) # advance time 5 minutes

      # Check out (without limit_override)
      checked_out = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=false", headers: headers).body).as_h
      checked_out["checked_in"].should eq(false)
    end

    it "#update does not check limit if the new start and end time is inside the existing range" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 1}))
      tenant.save!

      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   45.minutes.from_now.to_unix,
        booking_type:  "desk",
      }
      new_start_time = 10.minutes.from_now.to_unix

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      # Create booking with limit_override=true
      second_booking = BookingsHelper.http_create_booking(
        **common,
        asset_id: "second_desk",
        limit_override: "2")[1]
      second_booking["asset_id"].should eq("second_desk")

      booking_id = first_booking["id"].to_s

      # update booking
      updated = JSON.parse(client.patch("#{BOOKINGS_BASE}/#{booking_id}",
        headers: headers,
        body: %({"description": "Empty desk"})
      ).body).as_h
      updated["description"].should eq("Empty desk")

      # update booking time
      updated = JSON.parse(client.patch("#{BOOKINGS_BASE}/#{booking_id}",
        headers: headers,
        body: %({"booking_start":#{new_start_time}})
      ).body).as_h
      updated["booking_start"].should eq(new_start_time)
    end

    it "checked out bookins do not count towards the limit" do
      # Set booking limit
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 1}))
      tenant.save!

      common = {
        booking_start: 5.minutes.from_now.to_unix,
        booking_end:   45.minutes.from_now.to_unix,
        booking_type:  "desk",
      }

      first_booking = BookingsHelper.http_create_booking(**common, asset_id: "first_desk")[1]
      first_booking["asset_id"].should eq("first_desk")

      sleep(500.milliseconds) # advance time 5 minutes
      booking_id = first_booking["id"].to_s

      # check in
      checked_in = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=true", headers: headers).body).as_h
      checked_in["checked_in"].should eq(true)

      sleep(500.milliseconds) # advance time 5 minutes

      # Check out
      checked_out = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/check_in?state=false", headers: headers).body).as_h
      checked_out["checked_in"].should eq(false)

      second_booking = BookingsHelper.http_create_booking(
        booking_start: 5.minutes.from_now.to_unix,
        booking_end: 15.minutes.from_now.to_unix,
        booking_type: "desk",
        asset_id: "second_desk")[1]
      second_booking["asset_id"].should eq("second_desk")
    end
  end

  it "#prevents a booking being saved with an end time before the start time" do
    tenant = get_tenant
    expect_raises(PgORM::Error::RecordInvalid) do
      booking = BookingsHelper.create_booking(tenant_id: tenant.id)
      booking.booking_end = booking.booking_start - 2
      booking.save!
    end
  end

  it "#allows a booking once previous has been checked out" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    tenant = get_tenant
    booking = BookingsHelper.create_booking(tenant.id.not_nil!, 1.minutes.from_now.to_unix, 20.minutes.from_now.to_unix)
    booking.checked_out_at = 10.minutes.from_now.to_unix
    booking.save!

    sleep 2

    should_create = BookingsHelper.http_create_booking(
      booking_start: 15.minutes.from_now.to_unix,
      booking_end: 25.minutes.from_now.to_unix)[0]
    should_create.should eq(201)
  end

  it "prevents checking back in once checked out" do
    Timecop.scale(1)

    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")

    tenant = get_tenant
    asset_id = "asset-#{Random.new.rand(500)}"
    booking = BookingsHelper.create_booking(tenant.id.not_nil!, 4.minutes.from_now.to_unix, 20.minutes.from_now.to_unix, asset_id)
    booking.checked_out_at = 10.minutes.from_now.to_unix
    booking.checked_in = false
    booking.save!

    BookingsHelper.create_booking(tenant.id.not_nil!, 15.minutes.from_now.to_unix, 25.minutes.from_now.to_unix, asset_id)

    sleep 2

    not_checked_in = client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in", headers: headers).status_code
    not_checked_in.should eq(405)
  end

  it "prevents checking in after a booking has ended" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")

    booking = BookingsHelper.http_create_booking(
      booking_start: 20.minutes.ago.to_unix,
      booking_end: 5.minutes.ago.to_unix,
    )[1]

    not_checked_in = client.post("#{BOOKINGS_BASE}/#{booking["id"]}/check_in", headers: headers).status_code
    not_checked_in.should eq(405)
  end

  it "#prevents a booking being saved with an end time the same as the start time" do
    tenant = get_tenant
    expect_raises(PgORM::Error::RecordInvalid) do
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
    tenant = get_tenant
    booking = BookingsHelper.create_booking(tenant.id.not_nil!)

    body = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking.id}/approve", headers: headers).body).as_h
    booking = Booking.find_by(user_id: booking.user_id)
    body["approved"].should eq(true)
    body["approver_id"].should eq(booking.approver_id)
    body["approver_email"].should eq(booking.approver_email)
    body["approver_name"].should eq(booking.approver_name)
    body["rejected"].should eq(false)

    # Test rejection
    body = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking.id}/reject", headers: headers).body).as_h
    body["rejected"].should eq(true)
    body["approved"].should eq(false)
    # Reset approver info
    body["approver_id"]?.should eq(booking.approver_id)
    body["approver_email"]?.should eq(booking.approver_email)
    body["approver_name"]?.should eq(booking.approver_name)
  end

  it "#check_in should set checked_in state of a booking" do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(tenant.id.not_nil!)

    body = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", headers: headers).body).as_h
    body["checked_in"].should eq(true)

    body = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", headers: headers).body).as_h
    body["checked_in"].should eq(false)
  end

  it "#create and #update parent child" do
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

    created = JSON.parse(client.post(BOOKINGS_BASE, headers: headers,
      body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","attendees": [
      {
          "name": "#{user_name}",
          "email": "#{user_email}",
          "checked_in": true,
          "visit_expected": true
      }]})
    ).body)
    created["asset_id"].should eq("some_desk")
    created["booking_start"].should eq(starting)
    created["booking_end"].should eq(ending)

    parent_id = created["id"]

    child = JSON.parse(client.post(BOOKINGS_BASE, headers: headers,
      body: %({"parent_id": #{parent_id},"asset_id":"some_locker","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","attendees": [
    {
        "name": "#{user_name}",
        "email": "#{user_email}",
        "checked_in": true,
        "visit_expected": true
    }]})
    ).body)
    child["asset_id"].should eq("some_locker")
    child["booking_start"].should eq(starting)
    child["booking_end"].should eq(ending)
    child["parent_id"].should eq(parent_id)

    child_id = child["id"]

    # Changing start/end time should be cascaded to children
    starting = Random.new.rand(5..19).minutes.from_now.to_unix
    ending = Random.new.rand(25..39).minutes.from_now.to_unix

    updated = JSON.parse(client.patch("#{BOOKINGS_BASE}/#{parent_id}", headers: headers,
      body: %({"asset_id":"some_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk"})).body)

    updated["booking_start"].should eq(starting)
    updated["booking_end"].should eq(ending)
    updated["linked_bookings"][0]["booking_start"].should eq(starting)
    updated["linked_bookings"][0]["booking_end"].should eq(ending)

    # Updating start/end on child should fail
    starting = Random.new.rand(5..19).minutes.from_now.to_unix
    ending = Random.new.rand(25..39).minutes.from_now.to_unix

    updated = client.patch("#{BOOKINGS_BASE}/#{child_id}", headers: headers,
      body: %({"asset_id":"some_locker","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk"})).status_code

    updated.should eq(405)

    # Deleting parent booking should delete all its children as well
    deleted = client.delete("#{BOOKINGS_BASE}/#{parent_id}/", headers: headers).status_code
    deleted.should eq(202)
    booking = Booking.find(parent_id.as_i64)
    booking.children.not_nil!.size.should be > 0
    # check that it was deleted
    booking.deleted.should be_true
    booking.children.not_nil!.all? { |b| b.deleted == true }.should be_true
  end
end
