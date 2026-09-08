require "../spec_helper"
require "./helpers/booking_helper"

# request body for a desk booking owned by owner@example.com in the managed zone
def approval_spec_booking_json(approved = nil, rejected = nil, asset_id = "desk-approval")
  {
    user_id:       "owner@example.com",
    user_email:    "owner@example.com",
    user_name:     "Owner",
    asset_id:      asset_id,
    asset_ids:     [asset_id],
    zones:         ["zone-perm-org"],
    booking_type:  "desk",
    booking_start: 5.minutes.from_now.to_unix,
    booking_end:   1.hour.from_now.to_unix,
    approved:      approved,
    rejected:      rejected,
  }.to_h.compact!.to_json
end

describe Bookings do
  Spec.before_each {
    Booking.clear
    Attendee.truncate
    Guest.truncate
  }

  client = AC::SpecHelper.client
  admin_headers = Mock::Headers.office365_guest
  # zone-perm-org grants `manage` to the concierge group (see Mock::Token.org_zone)
  manager_headers = Mock::Headers.office365_normal_user(email: "concierge@example.com", groups: ["concierge"])
  owner_headers = Mock::Headers.office365_normal_user(email: "owner@example.com")
  other_headers = Mock::Headers.office365_normal_user(email: "other@example.com")

  # saving a booking spawns signals to the placeos engine, stub the outbound calls
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

  # an unapproved booking owned by owner@example.com, created by an admin
  create_pending = -> do
    status, body = BookingsHelper.http_create_booking(
      user_id: "owner@example.com",
      user_email: "owner@example.com",
      user_name: "Owner",
      asset_id: "desk-approval",
      zones: ["zone-perm-org"],
    )
    status.should eq(201)
    body["approved"].should be_false
    body["id"].as_i64
  end

  describe "approval permissions" do
    describe "#approve & #reject" do
      it "forbids users without approval permissions" do
        stub_engine.call
        id = create_pending.call

        client.post("#{BOOKINGS_BASE}/#{id}/approve", headers: owner_headers).status_code.should eq(403)
        client.post("#{BOOKINGS_BASE}/#{id}/approve", headers: other_headers).status_code.should eq(403)
        client.post("#{BOOKINGS_BASE}/#{id}/reject", headers: owner_headers).status_code.should eq(403)
        client.post("#{BOOKINGS_BASE}/#{id}/reject", headers: other_headers).status_code.should eq(403)

        booking = Booking.find!(id)
        booking.approved.should be_false
        booking.rejected.should be_false
        booking.approver_email.should be_nil
      end

      it "allows zone managers" do
        stub_engine.call
        id = create_pending.call

        response = client.post("#{BOOKINGS_BASE}/#{id}/approve", headers: manager_headers)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_true
        body["rejected"].should be_false
        body["approver_email"].should eq("concierge@example.com")
        body["approved_at"].as_i64.should be > 0

        response = client.post("#{BOOKINGS_BASE}/#{id}/reject", headers: manager_headers)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_false
        body["rejected"].should be_true
        body["approver_email"].should eq("concierge@example.com")
        body["rejected_at"].as_i64.should be > 0
      end

      it "allows admins" do
        stub_engine.call
        id = create_pending.call

        response = client.post("#{BOOKINGS_BASE}/#{id}/approve", headers: admin_headers)
        response.status_code.should eq(200)
        JSON.parse(response.body)["approved"].should be_true
      end
    end

    describe "#create" do
      it "forbids creating an approved or rejected booking without permission" do
        stub_engine.call

        client.post(BOOKINGS_BASE, headers: owner_headers, body: approval_spec_booking_json(approved: true)).status_code.should eq(403)
        client.post(BOOKINGS_BASE, headers: owner_headers, body: approval_spec_booking_json(rejected: true)).status_code.should eq(403)
        client.post(BOOKINGS_BASE, headers: other_headers, body: approval_spec_booking_json(approved: true)).status_code.should eq(403)

        Booking.where(asset_id: "desk-approval").to_a.should be_empty
      end

      it "allows users without permission to create pending bookings" do
        stub_engine.call

        response = client.post(BOOKINGS_BASE, headers: owner_headers, body: approval_spec_booking_json(approved: false, rejected: false))
        response.status_code.should eq(201)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_false
        body["rejected"].should be_false
        body["approver_email"]?.should be_nil
      end

      it "allows zone managers to create approved or rejected bookings" do
        stub_engine.call

        response = client.post(BOOKINGS_BASE, headers: manager_headers, body: approval_spec_booking_json(approved: true))
        response.status_code.should eq(201)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_true
        body["rejected"].should be_false
        body["approver_email"].should eq("concierge@example.com")
        body["approved_at"].as_i64.should be > 0

        response = client.post(BOOKINGS_BASE, headers: manager_headers, body: approval_spec_booking_json(rejected: true, asset_id: "desk-rejected"))
        response.status_code.should eq(201)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_false
        body["rejected"].should be_true
        body["approver_email"].should eq("concierge@example.com")
        body["rejected_at"].as_i64.should be > 0
      end

      it "allows admins to create approved bookings" do
        stub_engine.call

        response = client.post(BOOKINGS_BASE, headers: admin_headers, body: approval_spec_booking_json(approved: true))
        response.status_code.should eq(201)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_true
        body["approver_email"]?.should_not be_nil
      end
    end

    describe "#update" do
      it "forbids the booking owner changing the approval state" do
        stub_engine.call
        id = create_pending.call

        client.patch("#{BOOKINGS_BASE}/#{id}", headers: owner_headers, body: {approved: true}.to_json).status_code.should eq(403)
        client.patch("#{BOOKINGS_BASE}/#{id}", headers: owner_headers, body: {rejected: true}.to_json).status_code.should eq(403)

        # other edits are still permitted
        response = client.patch("#{BOOKINGS_BASE}/#{id}", headers: owner_headers, body: {title: "updated"}.to_json)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["title"].should eq("updated")
        body["approved"].should be_false
        body["rejected"].should be_false
      end

      it "allows the owner to echo back the current approval state" do
        stub_engine.call
        id = create_pending.call
        client.post("#{BOOKINGS_BASE}/#{id}/approve", headers: manager_headers).status_code.should eq(200)

        response = client.patch("#{BOOKINGS_BASE}/#{id}", headers: owner_headers, body: {title: "updated", approved: true, rejected: false}.to_json)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["title"].should eq("updated")
        body["approved"].should be_true
        body["approver_email"].should eq("concierge@example.com")
      end

      it "forbids the owner resetting an approved booking" do
        stub_engine.call
        id = create_pending.call
        client.post("#{BOOKINGS_BASE}/#{id}/approve", headers: manager_headers).status_code.should eq(200)

        client.patch("#{BOOKINGS_BASE}/#{id}", headers: owner_headers, body: {approved: false}.to_json).status_code.should eq(403)
        Booking.find!(id).approved.should be_true
      end

      it "allows zone managers to approve, reject and reset via update" do
        stub_engine.call
        id = create_pending.call

        response = client.patch("#{BOOKINGS_BASE}/#{id}", headers: manager_headers, body: {approved: true}.to_json)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_true
        body["rejected"].should be_false
        body["approver_email"].should eq("concierge@example.com")
        body["approved_at"].as_i64.should be > 0

        response = client.patch("#{BOOKINGS_BASE}/#{id}", headers: manager_headers, body: {rejected: true}.to_json)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_false
        body["rejected"].should be_true
        body["approver_email"].should eq("concierge@example.com")
        body["rejected_at"].as_i64.should be > 0

        response = client.patch("#{BOOKINGS_BASE}/#{id}", headers: manager_headers, body: {approved: false, rejected: false}.to_json)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_false
        body["rejected"].should be_false
        body["approver_email"]?.should be_nil
        body["approved_at"]?.should be_nil
        body["rejected_at"]?.should be_nil
      end

      it "keeps an explicit approval when a manager also changes the booking time" do
        stub_engine.call
        id = create_pending.call

        response = client.patch("#{BOOKINGS_BASE}/#{id}", headers: manager_headers, body: {
          booking_start: 2.hours.from_now.to_unix,
          booking_end:   3.hours.from_now.to_unix,
          approved:      true,
        }.to_json)
        response.status_code.should eq(200)
        body = JSON.parse(response.body).as_h
        body["approved"].should be_true
        body["approver_email"].should eq("concierge@example.com")
      end
    end
  end
end
