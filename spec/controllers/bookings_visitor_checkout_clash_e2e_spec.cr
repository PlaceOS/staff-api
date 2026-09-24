require "../spec_helper"
require "./helpers/booking_helper"

# End-to-end (HTTP) reproduction of: a new visitor booking is rejected as a
# conflicting booking when the previous booking on the same slot has already
# been checked out, early, before its scheduled end.
#
#   1. create a visitor booking 10:00 - 10:30
#   2. check the visitor in
#   3. check the visitor out at 10:09
#   4. create a new visitor booking 10:20 - 10:50 -> expected 201, not 409
#
# Check-in validates against the real clock (it can't happen after the booking
# ends, or too long before it starts), so every time here is relative to "now",
# which plays the part of 10:05 - 10:09 in the timeline above.
#
# There are two ways to check a visitor out, and they persist different things:
#   * booking level -- POST /bookings/:id/check_in?state=false sets
#     `bookings.checked_out_at`, which the clash queries exclude
#   * guest level   -- POST /bookings/:id/guests/:email/check_in?state=false only
#     flips the attendee's `checked_in` flag; the booking itself is untouched
describe Bookings do
  Spec.before_each do
    Booking.clear
    Attendee.truncate
    Guest.truncate
  end

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  # see the NOTE in bookings_clash_e2e_spec.cr -- these must be registered inside
  # each example, never in the global `Spec.before_each`
  stub_engine = -> do
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed").to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/host_changed").to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending").to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/checkin").to_return(body: "")
  end

  # creates a booking for the given visitors, returning the raw response
  create_visit = ->(booking_type : String, asset_id : String, visitor_emails : Array(String), starting : Int64, ending : Int64) do
    client.post(BOOKINGS_BASE, headers: headers, body: {
      asset_id:      asset_id,
      asset_ids:     [asset_id],
      zones:         ["zone-1234"],
      booking_type:  booking_type,
      booking_start: starting,
      booking_end:   ending,
      attendees:     visitor_emails.map { |email|
        {
          name:           "Visitor",
          email:          email,
          checked_in:     false,
          visit_expected: true,
        }
      },
    }.to_json)
  end

  # checks the visitor in or out, at the booking or the guest level
  set_checkin = ->(level : Symbol, booking_id : Int64, visitor_email : String, state : Bool) do
    path = case level
           when :booking then "#{BOOKINGS_BASE}/#{booking_id}/check_in?state=#{state}"
           else               "#{BOOKINGS_BASE}/#{booking_id}/guests/#{visitor_email}/check_in?state=#{state}"
           end
    response = client.post(path, headers: headers)
    fail "#{level} check_in(state=#{state}) failed #{response.status_code}: #{response.body}" unless response.success?
    response
  end

  # runs steps 1-3 of the timeline
  visit_then_check_out = ->(booking_type : String, asset_id : String, level : Symbol) do
    visitor = "first.visitor@external.com"
    response = create_visit.call(booking_type, asset_id, [visitor], 5.minutes.ago.to_unix, 25.minutes.from_now.to_unix)
    fail "first booking failed #{response.status_code}: #{response.body}" unless response.status_code == 201
    booking_id = JSON.parse(response.body)["id"].as_i64

    set_checkin.call(level, booking_id, visitor, true)
    set_checkin.call(level, booking_id, visitor, false)
  end

  # step 4: a second visitor booked into the slot the first visitor has vacated
  next_visit = ->(booking_type : String, asset_id : String) do
    create_visit.call(booking_type, asset_id, ["second.visitor@external.com"], 10.minutes.from_now.to_unix, 40.minutes.from_now.to_unix)
  end

  expect_created = ->(response : HTTP::Client::Response) do
    fail "expected 201 CREATED, got #{response.status_code}: #{response.body}" unless response.status_code == 201
  end

  # creates the first room booking for the given visitors, returning its id
  first_room_visit = ->(asset_id : String, visitor_emails : Array(String)) do
    response = create_visit.call("room", asset_id, visitor_emails, 5.minutes.ago.to_unix, 25.minutes.from_now.to_unix)
    expect_created.call(response)
    JSON.parse(response.body)["id"].as_i64
  end

  current_state = ->(booking_id : Int64) do
    JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}", headers: headers).body)["current_state"].as_s
  end

  {"visitor", "room"}.each do |booking_type|
    {:booking, :guest}.each do |level|
      it "allows a new #{booking_type} booking over a #{booking_type} booking checked out early (#{level} level check out)" do
        stub_engine.call
        asset_id = "#{booking_type}-slot-#{level}"

        visit_then_check_out.call(booking_type, asset_id, level)
        expect_created.call(next_visit.call(booking_type, asset_id))
      end
    end
  end

  # control: proves the second booking really does overlap the first, so the
  # examples above are exercising clash detection rather than passing trivially
  it "still rejects a new room booking over a room booking that has not been checked out" do
    stub_engine.call
    asset_id = "room-slot-control"

    first = create_visit.call("room", asset_id, ["first.visitor@external.com"], 5.minutes.ago.to_unix, 25.minutes.from_now.to_unix)
    expect_created.call(first)
    set_checkin.call(:booking, JSON.parse(first.body)["id"].as_i64, "first.visitor@external.com", true)

    next_visit.call("room", asset_id).status_code.should eq 409
  end

  # a guest level check out only releases the booking once no visitor is left on
  # site. `Attendee` records a single `checked_in` flag, so a visitor who has not
  # arrived yet is indistinguishable from one who has left -- neither holds the slot.
  describe "with several visitors" do
    visitor_a = "visitor.a@external.com"
    visitor_b = "visitor.b@external.com"

    it "keeps the booking active until the last visitor on site checks out" do
      stub_engine.call
      asset_id = "room-slot-multi"
      booking_id = first_room_visit.call(asset_id, [visitor_a, visitor_b])

      set_checkin.call(:guest, booking_id, visitor_a, true)
      set_checkin.call(:guest, booking_id, visitor_b, true)

      # visitor B is still in the room
      set_checkin.call(:guest, booking_id, visitor_a, false)
      current_state.call(booking_id).should eq "checked_in"
      next_visit.call("room", asset_id).status_code.should eq 409

      set_checkin.call(:guest, booking_id, visitor_b, false)
      current_state.call(booking_id).should eq "checked_out"
      expect_created.call(next_visit.call("room", asset_id))
    end

    it "releases the booking when the only visitor who arrived checks out" do
      stub_engine.call
      asset_id = "room-slot-partial"
      booking_id = first_room_visit.call(asset_id, [visitor_a, visitor_b])

      # visitor B never arrives
      set_checkin.call(:guest, booking_id, visitor_a, true)
      set_checkin.call(:guest, booking_id, visitor_a, false)

      current_state.call(booking_id).should eq "checked_out"
      expect_created.call(next_visit.call("room", asset_id))
    end

    it "releases the booking when a visitor who never arrived is checked out" do
      stub_engine.call
      asset_id = "room-slot-no-show"
      booking_id = first_room_visit.call(asset_id, [visitor_a])

      set_checkin.call(:guest, booking_id, visitor_a, false)

      current_state.call(booking_id).should eq "checked_out"
      expect_created.call(next_visit.call("room", asset_id))
    end
  end
end
