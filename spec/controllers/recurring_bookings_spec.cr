require "../spec_helper"
require "./helpers/booking_helper"
require "./helpers/guest_helper"

describe Bookings do
  Spec.before_each {
    Booking.clear
    Attendee.truncate
    Guest.truncate
  }

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "recurring bookings" do
    it "should support pagination" do
      tenant = get_tenant

      booking1 = BookingsHelper.create_booking(tenant.id.not_nil!)
      sleep 1
      booking2 = BookingsHelper.create_booking(tenant.id.not_nil!)
      sleep 1
      booking3 = BookingsHelper.create_booking(tenant.id.not_nil!)

      booking1.recurrence_type = :daily
      booking1.recurrence_days = 0b1111111
      booking1.timezone = "Europe/Berlin"
      booking1.booking_start = (Time.local.at_beginning_of_day + 8.hours).to_unix
      booking1.booking_end = (Time.local.at_beginning_of_day + 10.hours).to_unix
      booking1.save!

      booking2.booking_start = (Time.local.at_beginning_of_day + 8.hours).to_unix
      booking2.booking_end = (Time.local.at_beginning_of_day + 10.hours).to_unix
      booking2.save!

      booking3.booking_start = (Time.local.at_beginning_of_day + 8.hours).to_unix
      booking3.booking_end = (Time.local.at_beginning_of_day + 10.hours).to_unix
      booking3.save!

      starting = Time.local.at_beginning_of_day.to_unix
      ending = 4.days.from_now.to_unix

      # make initial request
      zones1 = booking1.zones.not_nil!
      zones_string = "#{zones1.first},#{booking2.zones.not_nil!.last},,#{booking3.zones.not_nil!.last}"
      route = "#{BOOKINGS_BASE}?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zones_string}&limit=2"
      result = client.get(route, headers: headers)

      result.success?.should be_true
      result.headers["X-Total-Count"].should eq "3"
      result.headers["Content-Range"].should eq "bookings 0-1/3"

      body = JSON.parse(result.body).as_a
      body.size.should eq(2)

      # make second request
      link = URI.decode(result.headers["Link"])
      link.should eq(%(<#{route}&offset=2>; rel="next"))
      next_link = link.split(">;")[0][1..]

      result = client.get(next_link, headers: headers)
      result.success?.should be_true

      body = JSON.parse(result.body).as_a
      body.size.should eq(2)
      result.headers["X-Total-Count"]?.should be_nil
      result.headers["Content-Range"]?.should be_nil

      # make third request
      link = URI.decode(result.headers["Link"])
      link.should eq(%(<#{route}&offset=2&recurrence=2>; rel="next"))
      next_link = link.split(">;")[0][1..]

      result = client.get(next_link, headers: headers)
      result.success?.should be_true

      body = JSON.parse(result.body).as_a
      body.size.should eq(2)
      result.headers["X-Total-Count"]?.should be_nil
      result.headers["Content-Range"]?.should be_nil

      # make final request
      link = URI.decode(result.headers["Link"])
      link.should eq(%(<#{route}&offset=2&recurrence=4>; rel="next"))
      next_link = link.split(">;")[0][1..]

      result = client.get(next_link, headers: headers)

      result.success?.should be_true
      body = JSON.parse(result.body).as_a
      body.size.should eq(1)

      result.headers["Link"]?.should be_nil
    end

    it "booking deleted before booking_start" do
      tenant = get_tenant

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      booking.recurrence_type = :daily
      booking.recurrence_days = 0b1111111
      booking.timezone = "Europe/Berlin"
      booking.save!

      booking.deleted.should be_false

      instances = booking.calculate_daily(2.days.from_now, 5.days.from_now).instances
      instance = instances.first.to_unix

      client.delete("#{BOOKINGS_BASE}/#{booking.id}/instance/#{instance}", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}/instance/#{instance}", headers: headers).body).as_h
      body["current_state"].should eq("cancelled")

      booking.reload!
      booking.deleted.should be_false

      other = instances.last.to_unix
      other.should_not eq instance
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}/instance/#{other}", headers: headers).body).as_h
      body["current_state"].should_not eq("cancelled")
    end

    it "check-in recurrence" do
      tenant = get_tenant

      booking = BookingsHelper.create_booking(tenant.id.not_nil!,
        booking_start: 1.minutes.from_now.to_unix,
        booking_end: 9.minutes.from_now.to_unix)

      booking.recurrence_type = :daily
      booking.recurrence_days = 0b1111111
      booking.timezone = "Europe/Berlin"
      booking.save!

      booking.checked_in.should be_false

      instances = booking.calculate_daily(2.days.from_now, 5.days.from_now).instances
      instance = instances.first.to_unix

      client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in/#{instance}", headers: headers)
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}/instance/#{instance}", headers: headers).body).as_h
      body["checked_in"].should be_true

      booking.reload!
      booking.checked_in.should be_false

      other = instances.last.to_unix
      other.should_not eq instance
      body = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking.id}/instance/#{other}", headers: headers).body).as_h
      body["checked_in"].should be_false
    end
  end
end
