require "../spec_helper"
require "./helpers/booking_helper"

describe Bookings do
  Spec.before_each {
    Booking.clear
    Attendee.truncate
    Guest.truncate
  }

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  # the approval flow saves the booking and spawns a signal to the placeos
  # engine -- stub the outbound calls so the spawned fibers don't hit the network
  stub_engine = -> do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/host_changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")
  end

  # create a daily recurring booking through the REST API and return its id
  create_recurring = ->(asset_id : String) do
    status, body = BookingsHelper.http_create_booking(
      asset_id: asset_id,
      booking_type: "desk",
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 9.minutes.from_now.to_unix,
      recurrence_type: "DAILY",
      recurrence_days: 0b1111111,
      timezone: "Europe/Berlin",
    )
    status.should eq(201)
    body["id"].as_i64
  end

  # the timestamp of one of the generated recurrence instances (not the first)
  instance_time = ->(booking_id : Int64) do
    booking = Booking.find(booking_id)
    booking.calculate_daily(2.days.from_now, 6.days.from_now).instances.first.to_unix
  end

  describe "recurring booking approval" do
    it "creates a recurring booking and approves one of its instances" do
      stub_engine.call

      booking_id = create_recurring.call("desk-approve-1")
      instance = instance_time.call(booking_id)

      # approve the single instance through the API
      response = client.post("#{BOOKINGS_BASE}/#{booking_id}/approve/#{instance}", headers: headers)
      response.success?.should be_true

      approved = JSON.parse(response.body).as_h
      approved["approved"].should eq true
      approved["instance"].should eq instance

      # the instance reports as approved when fetched back
      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["approved"].should eq true

      # the parent booking (and other occurrences) are left untouched
      parent = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}", headers: headers).body).as_h
      parent["approved"].should eq false
    end

    it "re-approves an instance that was previously rejected" do
      stub_engine.call

      booking_id = create_recurring.call("desk-approve-2")
      instance = instance_time.call(booking_id)

      # reject the instance first
      rejected = JSON.parse(client.post("#{BOOKINGS_BASE}/#{booking_id}/reject/#{instance}", headers: headers).body).as_h
      rejected["rejected"].should eq true

      # re-approving the same instance must succeed (updates the stored instance)
      response = client.post("#{BOOKINGS_BASE}/#{booking_id}/approve/#{instance}", headers: headers)
      response.success?.should be_true

      approved = JSON.parse(response.body).as_h
      approved["approved"].should eq true
      approved["rejected"].should eq false

      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["approved"].should eq true
      shown["rejected"].should eq false
    end

    it "approves only the targeted instance, leaving siblings unapproved" do
      stub_engine.call

      booking_id = create_recurring.call("desk-approve-3")
      booking = Booking.find(booking_id)
      instances = booking.calculate_daily(2.days.from_now, 6.days.from_now).instances
      target = instances.first.to_unix
      sibling = instances[1].to_unix
      target.should_not eq sibling

      client.post("#{BOOKINGS_BASE}/#{booking_id}/approve/#{target}", headers: headers).success?.should be_true

      approved = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{target}", headers: headers).body).as_h
      approved["approved"].should eq true

      other = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{sibling}", headers: headers).body).as_h
      other["approved"].should eq false
    end
  end

  describe "updating a recurring booking instance" do
    it "adjusts the end time to be a little earlier without a self clash" do
      stub_engine.call

      booking_id = create_recurring.call("desk-update-1")
      instance = instance_time.call(booking_id)

      # read the instance's current window
      current = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      original_start = current["booking_start"].as_i64
      original_end = current["booking_end"].as_i64
      earlier_end = original_end - 2.minutes.total_seconds.to_i64
      earlier_end.should be > original_start

      # shrink the instance so it ends a little earlier -- it overlaps only its
      # own (pre-edit) occurrence, which must be ignored, so there is no clash
      response = client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {booking_end: earlier_end}.to_json,
      )
      response.success?.should be_true
      response.status_code.should eq(200)

      updated = JSON.parse(response.body).as_h
      updated["booking_end"].as_i64.should eq earlier_end
      updated["booking_start"].as_i64.should eq original_start
      updated["instance"].as_i64.should eq instance

      # the shorter window is persisted on the instance, parent untouched
      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["booking_end"].as_i64.should eq earlier_end

      parent = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}", headers: headers).body).as_h
      parent["booking_end"].as_i64.should_not eq earlier_end
    end
  end
end
