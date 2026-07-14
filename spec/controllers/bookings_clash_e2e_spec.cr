require "../spec_helper"
require "./helpers/booking_helper"

# End-to-end (HTTP create) coverage proving the recurring / clashing booking bug
# is fixed: a clash that previously slipped through now returns 409 CONFLICT,
# while genuinely non-clashing bookings still succeed (201). Every booking here is
# created through the real POST /bookings controller path (clash detection,
# transaction, the lot) -- not seeded directly.
describe Bookings do
  Spec.before_each do
    Booking.clear
    Attendee.truncate
    Guest.truncate

    # the create action fans out signals to the engine -- stub them
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed").to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/host_changed").to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending").to_return(body: "")
  end

  # a fixed future anchor so the bookings are always valid (not in the past)
  base = Time.utc(2026, 7, 6, 0, 0, 0)
  rec_end = base.shift(days: 10).to_unix
  at = ->(day : Int32, hour : Int32, minute : Int32) { base.shift(days: day, hours: hour, minutes: minute).to_unix }

  status = ->(result : Tuple(Int32, Hash(String, JSON::Any))) { result[0] }

  describe "recurring vs a single-occurrence booking" do
    it "rejects a single booking that clashes with one occurrence of a recurring booking" do
      created = BookingsHelper.http_create_booking(
        asset_id: "desk-r1", booking_start: at.call(0, 10, 0), booking_end: at.call(0, 11, 0),
        recurrence_type: "DAILY", recurrence_end: rec_end, timezone: "UTC")
      status.call(created).should eq 201

      # a one-off booking landing on the recurring occurrence two days later
      clash = BookingsHelper.http_create_booking(
        asset_id: "desk-r1", booking_start: at.call(2, 10, 30), booking_end: at.call(2, 11, 30))
      status.call(clash).should eq 409
    end

    it "allows a single booking on the recurring asset at a non-overlapping time" do
      created = BookingsHelper.http_create_booking(
        asset_id: "desk-r2", booking_start: at.call(0, 10, 0), booking_end: at.call(0, 11, 0),
        recurrence_type: "DAILY", recurrence_end: rec_end, timezone: "UTC")
      status.call(created).should eq 201

      # same day as an occurrence, but a clear two hours later -> no clash
      ok = BookingsHelper.http_create_booking(
        asset_id: "desk-r2", booking_start: at.call(2, 13, 0), booking_end: at.call(2, 14, 0))
      status.call(ok).should eq 201
    end

    it "allows a single booking on a different asset at the same time as an occurrence" do
      created = BookingsHelper.http_create_booking(
        asset_id: "desk-r3", booking_start: at.call(0, 10, 0), booking_end: at.call(0, 11, 0),
        recurrence_type: "DAILY", recurrence_end: rec_end, timezone: "UTC")
      status.call(created).should eq 201

      ok = BookingsHelper.http_create_booking(
        asset_id: "desk-r3-other", booking_start: at.call(2, 10, 30), booking_end: at.call(2, 11, 30))
      status.call(ok).should eq 201
    end
  end

  describe "interleaved recurring bookings" do
    it "rejects two interleaved recurring bookings on the same asset (partial time overlap)" do
      first = BookingsHelper.http_create_booking(
        asset_id: "desk-i1", booking_start: at.call(0, 10, 0), booking_end: at.call(0, 12, 0),
        recurrence_type: "DAILY", recurrence_end: rec_end, timezone: "UTC")
      status.call(first).should eq 201

      # 11:00-13:00 daily overlaps 10:00-12:00 daily on every day
      second = BookingsHelper.http_create_booking(
        asset_id: "desk-i1", booking_start: at.call(0, 11, 0), booking_end: at.call(0, 13, 0),
        recurrence_type: "DAILY", recurrence_end: rec_end, timezone: "UTC")
      status.call(second).should eq 409
    end

    it "allows two adjacent recurring bookings on the same asset (no overlap)" do
      first = BookingsHelper.http_create_booking(
        asset_id: "desk-i2", booking_start: at.call(0, 10, 0), booking_end: at.call(0, 11, 0),
        recurrence_type: "DAILY", recurrence_end: rec_end, timezone: "UTC")
      status.call(first).should eq 201

      # 11:00-12:00 daily is adjacent to 10:00-11:00 daily -> no overlap
      second = BookingsHelper.http_create_booking(
        asset_id: "desk-i2", booking_start: at.call(0, 11, 0), booking_end: at.call(0, 12, 0),
        recurrence_type: "DAILY", recurrence_end: rec_end, timezone: "UTC")
      status.call(second).should eq 201
    end

    it "allows two recurring bookings on the same asset that fall on different weekdays" do
      monday = base
      until monday.day_of_week.monday?
        monday = monday.shift(days: 1)
      end
      tuesday = monday.shift(days: 1)
      mon_bit = 1 << 1 # Monday
      tue_bit = 1 << 2 # Tuesday
      week_end = monday.shift(days: 21).to_unix

      mon = BookingsHelper.http_create_booking(
        asset_id: "desk-i3",
        booking_start: monday.shift(hours: 10).to_unix, booking_end: monday.shift(hours: 11).to_unix,
        recurrence_type: "DAILY", recurrence_days: mon_bit, recurrence_end: week_end, timezone: "UTC")
      status.call(mon).should eq 201

      # same time-of-day and asset, but only ever lands on Tuesdays -> never clashes
      tue = BookingsHelper.http_create_booking(
        asset_id: "desk-i3",
        booking_start: tuesday.shift(hours: 10).to_unix, booking_end: tuesday.shift(hours: 11).to_unix,
        recurrence_type: "DAILY", recurrence_days: tue_bit, recurrence_end: week_end, timezone: "UTC")
      status.call(tue).should eq 201
    end
  end

  describe "all-day recurring bookings in a timezone east of UTC (prod regression desk.4-SE-076)" do
    perth = Time::Location.load("Australia/Perth") # UTC+8

    it "rejects a second overlapping all-day recurring booking that wraps UTC midnight" do
      # Perth-local 00:00 -> 23:59 wraps UTC midnight (16:00 prev day -> 15:59);
      # this is the row whose inverted time-of-day used to be dropped from the
      # candidate set, letting a duplicate through.
      b1_start = Time.local(2026, 7, 6, 0, 0, 0, location: perth)
      b1_end = Time.local(2026, 7, 6, 23, 59, 0, location: perth)
      perth_rec_end = b1_start.shift(days: 7).to_unix

      first = BookingsHelper.http_create_booking(
        asset_id: "desk.4-SE-076", booking_start: b1_start.to_unix, booking_end: b1_end.to_unix,
        recurrence_type: "DAILY", recurrence_end: perth_rec_end, timezone: "Australia/Perth")
      status.call(first).should eq 201

      # Perth-local 08:10 -> 23:59 (does NOT wrap), overlapping the same day/asset
      b2_start = Time.local(2026, 7, 6, 8, 10, 0, location: perth)
      b2_end = Time.local(2026, 7, 6, 23, 59, 0, location: perth)
      second = BookingsHelper.http_create_booking(
        asset_id: "desk.4-SE-076", booking_start: b2_start.to_unix, booking_end: b2_end.to_unix,
        recurrence_type: "DAILY", recurrence_end: perth_rec_end, timezone: "Australia/Perth")
      status.call(second).should eq 409
    end

    it "allows the second all-day recurring booking on a different desk" do
      b1_start = Time.local(2026, 7, 6, 0, 0, 0, location: perth)
      b1_end = Time.local(2026, 7, 6, 23, 59, 0, location: perth)
      perth_rec_end = b1_start.shift(days: 7).to_unix

      first = BookingsHelper.http_create_booking(
        asset_id: "desk.4-SE-076", booking_start: b1_start.to_unix, booking_end: b1_end.to_unix,
        recurrence_type: "DAILY", recurrence_end: perth_rec_end, timezone: "Australia/Perth")
      status.call(first).should eq 201

      b2_start = Time.local(2026, 7, 6, 8, 10, 0, location: perth)
      b2_end = Time.local(2026, 7, 6, 23, 59, 0, location: perth)
      second = BookingsHelper.http_create_booking(
        asset_id: "desk.4-SE-077", booking_start: b2_start.to_unix, booking_end: b2_end.to_unix,
        recurrence_type: "DAILY", recurrence_end: perth_rec_end, timezone: "Australia/Perth")
      status.call(second).should eq 201
    end
  end

  describe "interleaved single bookings" do
    it "rejects a partially overlapping single booking on the same asset" do
      first = BookingsHelper.http_create_booking(
        asset_id: "desk-s1", booking_start: at.call(0, 10, 0), booking_end: at.call(0, 12, 0))
      status.call(first).should eq 201

      second = BookingsHelper.http_create_booking(
        asset_id: "desk-s1", booking_start: at.call(0, 11, 0), booking_end: at.call(0, 13, 0))
      status.call(second).should eq 409
    end

    it "allows an adjacent single booking on the same asset" do
      first = BookingsHelper.http_create_booking(
        asset_id: "desk-s2", booking_start: at.call(0, 10, 0), booking_end: at.call(0, 11, 0))
      status.call(first).should eq 201

      second = BookingsHelper.http_create_booking(
        asset_id: "desk-s2", booking_start: at.call(0, 11, 0), booking_end: at.call(0, 12, 0))
      status.call(second).should eq 201
    end
  end
end
