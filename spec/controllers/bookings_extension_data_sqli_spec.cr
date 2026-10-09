require "../spec_helper"
require "./helpers/booking_helper"

# Security regression for the `extension_data` filter on GET /bookings.
#
# The `Booking.is_extension_data` scope used to interpolate the caller's key/value straight
# into SQL (`bookings.extension_data @> '<json>'`). A single quote in the value broke out of
# the string literal and reached Postgres as syntax -- proven end to end by this spec before
# the fix (placeos-models >= 9.119.1 now binds the value as a parameter and casts ::jsonb).
#
# The guard is differential: the ONLY difference between the two filtered requests is a single
# `'` appended to the value. A quote is ordinary data, so both must behave identically --
# 200 with the value simply matching nothing. If the scope ever regresses to string
# interpolation, the quoted request raises a Postgres error instead and this fails.
describe "Bookings#index extension_data SQL injection", tags: ["security", "sqli"] do
  Spec.before_each do
    Booking.clear
    Attendee.truncate
    Guest.truncate
  end

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  it "treats the extension_data filter value as data, not SQL" do
    starting = 5.minutes.from_now.to_unix
    ending = 40.minutes.from_now.to_unix
    period = "period_start=#{starting}&period_end=#{ending}&type=desk"

    # created as the requesting user so the index returns it
    create = client.post(BOOKINGS_BASE, headers: headers, body: %({"asset_id":"sqli_desk","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk","extension_data":{"foo":"bar"}}))
    create.status_code.should eq(201)

    # the filter matches the booking
    matched = client.get("#{BOOKINGS_BASE}?#{period}&extension_data={foo:bar}", headers: headers)
    matched.status_code.should eq(200)
    JSON.parse(matched.body).as_a.size.should eq(1)

    # a non-matching value is a clean, successful, empty result
    safe = client.get("#{BOOKINGS_BASE}?#{period}&extension_data={foo:zzz}", headers: headers)
    safe.status_code.should eq(200)
    JSON.parse(safe.body).as_a.should be_empty

    # the SAME value plus one single quote (URL-encoded %27) must behave identically: the
    # quote is bound as data, so it still just matches nothing -- no Postgres syntax error
    injected = client.get("#{BOOKINGS_BASE}?#{period}&extension_data={foo:zzz%27}", headers: headers)
    injected.status_code.should eq(200)
    JSON.parse(injected.body).as_a.should be_empty

    # a classic tautology payload is likewise inert
    tautology = client.get("#{BOOKINGS_BASE}?#{period}&extension_data={foo:x%27 OR %271%27=%271}", headers: headers)
    tautology.status_code.should eq(200)
    JSON.parse(tautology.body).as_a.should be_empty
  end
end
