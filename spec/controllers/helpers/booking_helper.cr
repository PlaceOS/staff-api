module BookingsHelper
  extend self

  def random_zones : Array(String)
    ["zone-#{Random.new.rand(500)}", "zone-#{Random.new.rand(500)}", "zone-#{Random.new.rand(500)}"]
  end

  def create_booking(tenant_id : Int64, user_email : String, zones : Array(String) = random_zones)
    user_name = Faker::Internet.user_name
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

  def create_booking(tenant_id : Int64, booking_start : Int64, booking_end : Int64)
    booking = create_booking(tenant_id)
    booking.booking_start = booking_start
    booking.booking_end = booking_end
    unless booking.save
      raise booking.errors.inspect
    end
    booking
  end

  def create_booking(tenant_id : Int64, user_email : String, zones : Array(String), booking_start : Int64, booking_end : Int64)
    booking = create_booking(
      tenant_id: tenant_id,
      user_email: user_email,
      zones: zones,
    )
    booking.booking_start = booking_start
    booking.booking_end = booking_end
    booking.save!
  end

  def create_booking(tenant_id : Int64, booking_start : Int64, booking_end : Int64, asset_id : String)
    booking = create_booking(tenant_id)
    booking.booking_start = booking_start
    booking.booking_end = booking_end
    booking.asset_id = asset_id
    booking.save!
  end

  def create_booking(tenant_id)
    user_email = Faker::Internet.email
    create_booking(tenant_id: tenant_id.not_nil!, user_email: user_email)
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
    department = nil,
    limit_override = nil
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

    client = AC::SpecHelper.client

    param = URI::Params.new
    param.add("utm_source", utm_source) if utm_source
    param.add("limit_override", limit_override) if limit_override
    uri = URI.new(path: BOOKINGS_BASE, query: param)
    response = client.post(uri.to_s,
      body: body,
      headers: Mock::Headers.office365_guest
    )
    if response.success?
      {response.status_code, JSON.parse(response.body).as_h}
    else
      {response.status_code, {} of String => JSON::Any}
    end
  end
end

BOOKINGS_BASE = Bookings.base_route
