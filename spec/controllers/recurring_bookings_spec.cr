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
      sleep 1.second
      booking2 = BookingsHelper.create_booking(tenant.id.not_nil!)
      sleep 1.second
      booking3 = BookingsHelper.create_booking(tenant.id.not_nil!)

      booking1.recurrence_type = :daily
      booking1.recurrence_days = 0b1111111
      booking1.timezone = "Europe/Berlin"
      booking1.booking_start = (Time.local.at_beginning_of_day + 4.hours).to_unix
      booking1.booking_end = (Time.local.at_beginning_of_day + 6.hours).to_unix
      booking1.save!

      booking2.booking_start = (Time.local.at_beginning_of_day + 4.hours).to_unix
      booking2.booking_end = (Time.local.at_beginning_of_day + 6.hours).to_unix
      booking2.save!

      booking3.booking_start = (Time.local.at_beginning_of_day + 4.hours).to_unix
      booking3.booking_end = (Time.local.at_beginning_of_day + 6.hours).to_unix
      booking3.save!

      starting = Time.local.at_beginning_of_day.to_unix
      ending = (Time.local.at_beginning_of_day + 4.5.days).to_unix

      # make initial request
      zones1 = booking1.zones.not_nil!
      zones_string = "#{zones1.first},#{booking2.zones.not_nil!.last},,#{booking3.zones.not_nil!.last}"
      route = "#{BOOKINGS_BASE}/?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zones_string}&limit=2"
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

    describe "pagination with deleted or rejected recurring bookings" do
      zone = "zone-recurring-pager"
      day_start = Time.local.at_beginning_of_day
      starting = day_start.to_unix
      ending = (day_start + 4.5.days).to_unix

      # a daily recurring booking with 5 occurrences in the queried period
      make_recurring = ->(tenant_id : Int64) do
        booking = BookingsHelper.create_booking(tenant_id)
        booking.zones = [zone]
        booking.recurrence_type = :daily
        booking.recurrence_days = 0b1111111
        booking.timezone = "Europe/Berlin"
        booking.booking_start = (day_start + 4.hours).to_unix
        booking.booking_end = (day_start + 6.hours).to_unix
        booking.save!
        booking
      end

      it "should not return a next link identical to the request when a page contains only deleted recurring bookings" do
        tenant_id = get_tenant.id.not_nil!
        deleted = 3.times.map do
          booking = make_recurring.call(tenant_id)
          booking.deleted = true
          booking.deleted_at = Time.utc.to_unix
          booking.save!
          booking
        end.to_a

        route = "#{BOOKINGS_BASE}/?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zone}&include_deleted=true&limit=2"
        seen = follow_booking_pages(client, route, headers)

        expected = deleted.map { |booking| {booking.id.not_nil!, nil.as(Int64?)} }
        seen.size.should eq expected.size
        seen.to_set.should eq expected.to_set
      end

      it "should paginate past rejected recurring bookings" do
        tenant_id = get_tenant.id.not_nil!
        rejected = 3.times.map do
          booking = make_recurring.call(tenant_id)
          booking.rejected = true
          booking.rejected_at = Time.utc.to_unix
          booking.save!
          booking
        end.to_a

        route = "#{BOOKINGS_BASE}/?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zone}&limit=2"
        seen = follow_booking_pages(client, route, headers)

        expected = rejected.map { |booking| {booking.id.not_nil!, nil.as(Int64?)} }
        seen.size.should eq expected.size
        seen.to_set.should eq expected.to_set
      end

      it "should return every instance once when active and deleted recurring bookings share a page" do
        tenant_id = get_tenant.id.not_nil!

        # the active booking is created first so it sorts before the deleted one on `created`
        active = make_recurring.call(tenant_id)
        sleep 1.second
        deleted = make_recurring.call(tenant_id)
        deleted.deleted = true
        deleted.deleted_at = Time.utc.to_unix
        deleted.save!

        route = "#{BOOKINGS_BASE}/?period_start=#{starting}&period_end=#{ending}&type=desk&zones=#{zone}&include_deleted=true&limit=2"
        seen = follow_booking_pages(client, route, headers)

        instances = active.calculate_daily(Time.unix(starting), Time.unix(ending)).instances
        instances.size.should eq 5

        expected = instances.map { |time| {active.id.not_nil!, time.to_unix.as(Int64?)} }
        expected << {deleted.id.not_nil!, nil.as(Int64?)}
        seen.size.should eq expected.size
        seen.to_set.should eq expected.to_set
      end
    end

    it "should delete a booking instance" do
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
      tenant.early_checkin = 99999999999_i64
      tenant.save!

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

# follows `Link: rel="next"` headers until the last page, returning every `{id, instance}` pair seen.
# fails if a page links back to the request that produced it, which is an infinite loop for clients.
def follow_booking_pages(client, route : String, headers) : Array({Int64, Int64?})
  seen = [] of {Int64, Int64?}
  next_route = route

  20.times do
    result = client.get(next_route, headers: headers)
    result.success?.should be_true

    JSON.parse(result.body).as_a.each do |booking|
      seen << {booking["id"].as_i64, booking["instance"]?.try(&.as_i64?)}
    end

    link = result.headers["Link"]?
    return seen unless link

    link_route = URI.decode(link.split(">;")[0][1..])
    link_params = URI.parse(link_route).query_params.to_h
    request_params = URI.parse(next_route).query_params.to_h
    link_params.should_not eq(request_params)

    next_route = link_route
  end

  raise "pagination did not terminate within 20 pages"
end
