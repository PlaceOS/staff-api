require "../spec_helper"
require "./helpers/booking_helper"

# The booking_period and booking_range checks live in placeos-models
# (Booking and BookingInstance validations), these cover them end to end.
# spec_helper resets both on the shared tenant before each example.
describe Bookings do
  Spec.before_each do
    Booking.clear
    Attendee.truncate
    Guest.truncate
  end

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  set_tenant = ->(booking_period : Hash(String, UInt32), booking_range : Hash(String, UInt32)) do
    tenant = get_tenant
    tenant.booking_period = booking_period
    tenant.booking_range = booking_range
    tenant.early_checkin = 99999999999_i64
    tenant.save!
    tenant
  end

  failed_fields = ->(response : HTTP::Client::Response) do
    JSON.parse(response.body)["failures"].as_a.map(&.["field"].as_s)
  end

  # a daily desk booking starting tomorrow, returns the booking and its next occurrence
  recurring = ->(tenant : Tenant, length : Time::Span) do
    starting = 1.day.from_now.at_beginning_of_hour
    booking = BookingsHelper.create_booking(tenant.id.not_nil!,
      booking_start: starting.to_unix,
      booking_end: (starting + length).to_unix)
    booking.recurrence_type = :daily
    booking.recurrence_days = 0b1111111
    booking.timezone = "UTC"
    booking.recurrence_end = 30.days.from_now.to_unix
    booking.save!
    {booking, booking.booking_start + 1.day.total_seconds.to_i64}
  end

  describe "tenant booking_period" do
    it "#create rejects a booking longer than the period" do
      set_tenant.call({"desk" => 1440_u32}, {} of String => UInt32)
      starting = 1.hour.from_now

      status, _body = BookingsHelper.http_create_booking(
        booking_start: starting.to_unix,
        booking_end: (starting + 25.hours).to_unix,
      )
      # http_create_booking drops the body of a failed response, #update covers the failure fields
      status.should eq 422
      Booking.count.should eq 0

      # exactly the limit is allowed
      status, body = BookingsHelper.http_create_booking(
        booking_start: starting.to_unix,
        booking_end: (starting + 24.hours).to_unix,
      )
      status.should eq 201
      body["booking_end"].as_i64.should eq (starting + 24.hours).to_unix
    end

    it "#create ignores booking types without a period" do
      set_tenant.call({"desk" => 60_u32}, {} of String => UInt32)
      starting = 1.hour.from_now

      status, _body = BookingsHelper.http_create_booking(
        booking_type: "parking",
        booking_start: starting.to_unix,
        booking_end: (starting + 3.days).to_unix,
      )
      status.should eq 201
    end

    it "#create checks each occurrence of a recurring booking, not the series" do
      set_tenant.call({"desk" => 120_u32}, {} of String => UInt32)
      starting = 1.day.from_now.at_beginning_of_hour

      status, _body = BookingsHelper.http_create_booking(
        booking_start: starting.to_unix,
        booking_end: (starting + 1.hour).to_unix,
        recurrence_type: "DAILY",
        recurrence_days: 0b1111111,
        recurrence_end: 20.days.from_now.to_unix,
        timezone: "UTC",
      )
      status.should eq 201

      status, _body = BookingsHelper.http_create_booking(
        asset_id: "asset-2",
        booking_start: starting.to_unix,
        booking_end: (starting + 3.hours).to_unix,
        recurrence_type: "DAILY",
        recurrence_days: 0b1111111,
        recurrence_end: 20.days.from_now.to_unix,
        timezone: "UTC",
      )
      status.should eq 422
    end

    it "#update rejects stretching a booking beyond the period" do
      tenant = set_tenant.call({"desk" => 120_u32}, {} of String => UInt32)
      starting = 1.hour.from_now.to_unix
      booking = BookingsHelper.create_booking(tenant.id.not_nil!, starting, starting + 3600)

      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}", headers: headers,
        body: {booking_end: starting + 3.hours.total_seconds.to_i64}.to_json)
      response.status_code.should eq 422
      failed_fields.call(response).should contain("booking_end")
      Booking.find(booking.id.not_nil!).booking_end.should eq starting + 3600

      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}", headers: headers,
        body: {booking_end: starting + 2.hours.total_seconds.to_i64}.to_json)
      response.status_code.should eq 200
      Booking.find(booking.id.not_nil!).booking_end.should eq starting + 2.hours.total_seconds.to_i64
    end

    it "#update allows unrelated changes to a booking made before the period was tightened" do
      tenant = get_tenant
      starting = 1.hour.from_now.to_unix
      booking = BookingsHelper.create_booking(tenant.id.not_nil!, starting, starting + 8.hours.total_seconds.to_i64)
      set_tenant.call({"desk" => 240_u32}, {} of String => UInt32)

      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}", headers: headers,
        body: {title: "renamed"}.to_json)
      response.status_code.should eq 200
      Booking.find(booking.id.not_nil!).title.should eq "renamed"
    end

    it "#update_instance rejects stretching an occurrence beyond the period" do
      tenant = set_tenant.call({"desk" => 120_u32}, {} of String => UInt32)
      booking, occurrence = recurring.call(tenant, 1.hour)

      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}/instance/#{occurrence}", headers: headers,
        body: {booking_end: occurrence + 3.hours.total_seconds.to_i64}.to_json)
      response.status_code.should eq 422
      failed_fields.call(response).should contain("booking_end")
      PlaceOS::Model::BookingInstance.where(id: booking.id.not_nil!, instance_start: occurrence).count.should eq 0

      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}/instance/#{occurrence}", headers: headers,
        body: {booking_end: occurrence + 2.hours.total_seconds.to_i64}.to_json)
      response.status_code.should eq 200
      JSON.parse(response.body)["booking_end"].as_i64.should eq occurrence + 2.hours.total_seconds.to_i64

      # the rest of the series is untouched
      series = Booking.find(booking.id.not_nil!)
      (series.booking_end - series.booking_start).should eq 3600
    end

    it "allows checking in and moving an occurrence of a series made before the period was tightened" do
      booking, occurrence = recurring.call(get_tenant, 8.hours)
      set_tenant.call({"desk" => 240_u32}, {} of String => UInt32)

      response = client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in/#{occurrence}?state=true", headers: headers)
      response.status_code.should eq 200
      JSON.parse(response.body)["checked_in"].as_bool.should be_true

      # moving it keeps its length, so it is still allowed
      moved = occurrence + 1.hour.total_seconds.to_i64
      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}/instance/#{occurrence}", headers: headers,
        body: {booking_start: moved, booking_end: moved + 8.hours.total_seconds.to_i64}.to_json)
      response.status_code.should eq 200

      # but it can't be stretched further
      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}/instance/#{occurrence}", headers: headers,
        body: {booking_end: moved + 9.hours.total_seconds.to_i64}.to_json)
      response.status_code.should eq 422
    end
  end

  describe "tenant booking_range" do
    it "#create rejects an open-ended recurring booking" do
      set_tenant.call({} of String => UInt32, {"desk" => 7_u32})
      starting = 1.day.from_now.at_beginning_of_hour
      recurrence = {
        booking_start:   starting.to_unix,
        booking_end:     (starting + 1.hour).to_unix,
        recurrence_type: "DAILY",
        recurrence_days: 0b1111111,
        timezone:        "UTC",
      }

      status, _body = BookingsHelper.http_create_booking(**recurrence)
      status.should eq 422
      Booking.count.should eq 0

      status, _body = BookingsHelper.http_create_booking(**recurrence, recurrence_end: 5.days.from_now.to_unix)
      status.should eq 201

      # booking types without a range can still be open-ended
      status, _body = BookingsHelper.http_create_booking(**recurrence, booking_type: "parking", asset_id: "car-1")
      status.should eq 201
    end

    it "#update rejects making a booking an open-ended series" do
      tenant = set_tenant.call({} of String => UInt32, {"desk" => 7_u32})
      starting = 1.hour.from_now.to_unix
      booking = BookingsHelper.create_booking(tenant.id.not_nil!, starting, starting + 3600)
      # #update doesn't take a timezone, which recurring bookings also require
      booking.timezone = "UTC"
      booking.save!

      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}", headers: headers,
        body: {recurrence_type: "DAILY", recurrence_days: 0b1111111}.to_json)
      response.status_code.should eq 422
      failed_fields.call(response).should eq ["recurrence_end"]
      Booking.find(booking.id.not_nil!).recurrence_type.none?.should be_true
    end

    it "#update_instance rejects moving an occurrence beyond the range" do
      tenant = get_tenant
      booking, occurrence = recurring.call(tenant, 1.hour)
      booking.recurrence_end = 5.days.from_now.to_unix
      booking.save!
      set_tenant.call({} of String => UInt32, {"desk" => 7_u32})

      moved = occurrence + 9.days.total_seconds.to_i64
      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}/instance/#{occurrence}", headers: headers,
        body: {booking_start: moved, booking_end: moved + 3600}.to_json)
      response.status_code.should eq 422
      failed_fields.call(response).should contain("booking_end")

      moved = occurrence + 3.hours.total_seconds.to_i64
      response = client.patch("#{BOOKINGS_BASE}/#{booking.id}/instance/#{occurrence}", headers: headers,
        body: {booking_start: moved, booking_end: moved + 3600}.to_json)
      response.status_code.should eq 200
    end

    it "allows approving an occurrence of a series made before the range was tightened" do
      booking, _occurrence = recurring.call(get_tenant, 1.hour)
      set_tenant.call({} of String => UInt32, {"desk" => 7_u32})
      occurrence = booking.booking_start + 20.days.total_seconds.to_i64

      response = client.post("#{BOOKINGS_BASE}/#{booking.id}/approve/#{occurrence}", headers: headers)
      response.status_code.should eq 200
      JSON.parse(response.body)["approved"].as_bool.should be_true
    end
  end
end
