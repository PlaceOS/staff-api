require "../spec_helper"
require "./helpers/booking_helper"

EXT_DATA_ZONES = ["zone-ext-data-1", "zone-ext-data-2", "zone-ext-data-3"]

# modelled on a real "Parking Request" booking from the workplace app
PARKING_EXT_DATA = {
  "location"                 => "Test Street",
  "booking_asset"            => {} of String => String,
  "secondary_resource"       => {} of String => String,
  "attendance_type"          => "ANY",
  "plate_number"             => "testplate1",
  "vehicle_type"             => "motorcycle",
  "request_type"             => "standard",
  "space_restrictions"       => 1,
  "extra_space_restrictions" => [] of String,
  "attachments"              => [] of String,
  "group"                    => "",
  "assets"                   => [] of String,
  "requires_manual_approval" => false,
  "user_groups"              => ["Test Concierge Users", "placeos_admin"],
  "department"               => "",
  "tags"                     => [] of String,
  "app_name"                 => "Workplace",
  "app_version"              => "abc1234",
}

# End to end coverage for `extension_data` on recurring bookings.
#
# The parent booking carries the extension data, individual occurrences are
# virtual until something is changed on them. An occurrence continues to inherit
# extension data when only another field changes. Once its extension data is
# explicitly updated, the `BookingInstance` row holds a complete snapshot of the
# effective data and no longer inherits later extension-data changes from the
# parent series.
describe Bookings do
  Spec.before_each {
    Booking.clear
    PlaceOS::Model::BookingInstance.clear
    Attendee.truncate
    Guest.truncate
  }

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  # updating an instance saves the booking and spawns a signal to the placeos
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

  # create a daily recurring parking booking, carrying extension data, through
  # the REST API. Returns {id, booking_start, booking_end}
  create_recurring = ->(asset_id : String) do
    booking_start = 1.minutes.from_now.to_unix
    booking_end = 9.minutes.from_now.to_unix

    body = {
      user_id:         "jon@example.com",
      user_email:      "jon@example.com",
      user_name:       "Jon Smith",
      asset_id:        asset_id,
      asset_ids:       [asset_id],
      zones:           EXT_DATA_ZONES,
      booking_type:    "parking",
      title:           "Parking Request",
      description:     "Parking Request",
      booking_start:   booking_start,
      booking_end:     booking_end,
      booked_by_email: "jon@example.com",
      booked_by_id:    "jon@example.com",
      booked_by_name:  "Jon Smith",
      timezone:        "Australia/Perth",
      permission:      "PRIVATE",

      extension_data: PARKING_EXT_DATA,

      recurrence_type:     "DAILY",
      recurrence_days:     0b1111111,
      recurrence_interval: 1,
      recurrence_end:      10.days.from_now.to_unix,
    }.to_json

    response = client.post(BOOKINGS_BASE, body: body, headers: headers)
    puts "failed to create booking: #{response.body}" unless response.success?
    response.status_code.should eq(201)

    created = JSON.parse(response.body).as_h
    created["extension_data"]["plate_number"].should eq("testplate1")

    {created["id"].as_i64, booking_start, booking_end}
  end

  # the occurrences of the recurring booking, a few days out from the parent
  instances_of = ->(booking_id : Int64) do
    Booking.find(booking_id).calculate_daily(2.days.from_now, 6.days.from_now).instances.map(&.to_unix)
  end

  # list the bookings (parent + expanded occurrences) over the recurrence range
  list_bookings = -> do
    starting = Time.local.at_beginning_of_day.to_unix
    ending = (Time.local.at_beginning_of_day + 7.days).to_unix
    route = "#{BOOKINGS_BASE}/?period_start=#{starting}&period_end=#{ending}&type=parking&zones=#{EXT_DATA_ZONES.first}"
    response = client.get(route, headers: headers)
    response.success?.should be_true
    JSON.parse(response.body).as_a.map(&.as_h)
  end

  describe "recurring booking extension data" do
    it "returns the parent's extension data on every expanded occurrence" do
      stub_engine.call

      booking_id, _start, _end = create_recurring.call("unallocated-Ez15vtMs")

      listed = list_bookings.call
      listed.size.should be > 1

      listed.each do |occurrence|
        occurrence["id"].as_i64.should eq booking_id
        occurrence["extension_data"]["plate_number"].should eq("testplate1")
        occurrence["extension_data"]["location"].should eq("Test Street")
      end
    end

    it "keeps the parent's extension data on an occurrence after its asset_id is changed" do
      stub_engine.call

      booking_id, _start, _end = create_recurring.call("unallocated-Ez15vtMs")
      instance = instances_of.call(booking_id).first

      # the occurrence carries the parent's extension data before the change
      before = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      before["extension_data"]["plate_number"].should eq("testplate1")

      # allocate a real bay to this one occurrence
      response = client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {asset_id: "parking-bay-7", asset_ids: ["parking-bay-7"]}.to_json,
      )
      puts "failed to update instance: #{response.body}" unless response.success?
      response.success?.should be_true

      updated = JSON.parse(response.body).as_h
      updated["asset_id"].should eq("parking-bay-7")
      updated["instance"].as_i64.should eq instance

      # >>> the reported bug: extension data must survive the asset change
      updated["extension_data"]["plate_number"].should eq("testplate1")
      updated["extension_data"]["location"].should eq("Test Street")

      # and it must still be there when the occurrence is read back
      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["asset_id"].should eq("parking-bay-7")
      shown["extension_data"]["plate_number"].should eq("testplate1")
      shown["extension_data"]["location"].should eq("Test Street")
      shown["extension_data"]["user_groups"].as_a.map(&.as_s).should eq(["Test Concierge Users", "placeos_admin"])
    end

    it "keeps the extension data on sibling occurrences after one asset_id is changed" do
      stub_engine.call

      booking_id, _start, _end = create_recurring.call("unallocated-Ez15vtMs")
      instance = instances_of.call(booking_id).first

      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {asset_id: "parking-bay-7", asset_ids: ["parking-bay-7"]}.to_json,
      ).success?.should be_true

      listed = list_bookings.call
      listed.size.should be > 1

      listed.each do |occurrence|
        occurrence["extension_data"]["plate_number"].should eq("testplate1"),
          "occurrence #{occurrence["instance"]?} lost its extension data: #{occurrence["extension_data"]}"
        occurrence["extension_data"]["location"].should eq("Test Street")
      end

      # only the targeted occurrence changed asset
      changed = listed.select { |occurrence| occurrence["instance"]?.try(&.as_i64) == instance }
      changed.size.should eq(1)
      changed.first["asset_id"].should eq("parking-bay-7")

      listed.reject { |occurrence| occurrence["instance"]?.try(&.as_i64) == instance }.each do |occurrence|
        occurrence["asset_id"].should eq("unallocated-Ez15vtMs")
      end
    end

    {
      "JSON null"       => JSON::Any.new(nil),
      "an empty object" => JSON::Any.new({} of String => JSON::Any),
    }.each do |description, extension_data|
      it "keeps inheriting when an occurrence update sends #{description}" do
        stub_engine.call

        booking_id, _start, _end = create_recurring.call("unallocated-Ez15vtMs")
        instance = instances_of.call(booking_id).first

        response = client.patch(
          "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
          headers: headers,
          body: {
            "asset_id"       => JSON::Any.new("parking-bay-7"),
            "extension_data" => extension_data,
          }.to_json,
        )
        puts "failed to update instance: #{response.body}" unless response.success?
        response.success?.should be_true

        stored = PlaceOS::Model::BookingInstance
          .where(id: booking_id, instance_start: instance)
          .first
        stored.extension_data.try(&.as_h?).should be_nil

        client.patch(
          "#{BOOKINGS_BASE}/#{booking_id}/ext_data",
          headers: headers,
          body: {location: "Second Street"}.to_json,
        ).success?.should be_true

        inherited = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
        inherited["extension_data"]["location"].should eq("Second Street")
      end
    end

    it "snapshots the effective extension data when an occurrence is updated" do
      stub_engine.call

      booking_id, _start, _end = create_recurring.call("unallocated-Ez15vtMs")
      instance = instances_of.call(booking_id).first

      # the workplace app sends the whole booking back, extension data included
      response = client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {
          asset_id:       "parking-bay-7",
          asset_ids:      ["parking-bay-7"],
          extension_data: {"plate_number" => "testplate2"},
        }.to_json,
      )
      puts "failed to update instance: #{response.body}" unless response.success?
      response.success?.should be_true

      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      # the supplied key is overridden ...
      shown["extension_data"]["plate_number"].should eq("testplate2")
      # ... and the complete effective value is captured on the instance
      shown["extension_data"]["location"].should eq("Test Street")
      shown["extension_data"]["app_name"].should eq("Workplace")

      stored = PlaceOS::Model::BookingInstance
        .where(id: booking_id, instance_start: instance)
        .first.extension_data.not_nil!.as_h
      stored.keys.sort!.should eq(PARKING_EXT_DATA.keys.sort!)
      stored["plate_number"].should eq("testplate2")
      stored["location"].should eq("Test Street")

      # the parent booking is left untouched
      parent = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}", headers: headers).body).as_h
      parent["extension_data"]["plate_number"].should eq("testplate1")
      parent["asset_id"].should eq("unallocated-Ez15vtMs")

      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/ext_data",
        headers: headers,
        body: {location: "Second Street"}.to_json,
      ).success?.should be_true

      snapshotted = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      snapshotted["extension_data"]["plate_number"].should eq("testplate2")
      snapshotted["extension_data"]["location"].should eq("Test Street")
    end
  end

  # the reported booking is a Perth (UTC+8) parking request running 07:00 - 17:30
  # local, i.e. 23:00 - 09:30 *UTC*: the stored time-of-day window wraps past UTC
  # midnight. It is also posted the way the workplace app posts it -- an
  # `unallocated-*` asset_id with an empty asset_ids array.
  describe "a Perth parking request that wraps UTC midnight" do
    perth = Time::Location.load("Australia/Perth")

    # create the series exactly as the workplace app does
    create_parking = -> do
      first_day = Time.local(perth).at_beginning_of_day + 1.day
      booking_start = (first_day + 7.hours).to_unix
      booking_end = (first_day + 17.hours + 30.minutes).to_unix

      body = {
        asset_id:      "unallocated-Ez15vtMs",
        asset_ids:     [] of String,
        asset_name:    "Parking Request",
        zones:         EXT_DATA_ZONES,
        booking_start: booking_start,
        booking_end:   booking_end,
        booking_type:  "parking",
        timezone:      "Australia/Perth",
        user_email:    "will.tester@example.com",
        user_name:     "Will Tester",
        title:         "Parking Request",
        description:   "Parking Request",
        checked_in:    false,
        rejected:      false,
        approved:      false,
        deleted:       false,
        all_day:       false,
        permission:    "PRIVATE",

        extension_data: PARKING_EXT_DATA,

        recurrence_type:         "daily",
        recurrence_days:         56, # wed, thu, fri
        recurrence_nth_of_month: 0,
        recurrence_interval:     1,
        recurrence_end:          (first_day + 21.days).to_unix,
      }.to_json

      response = client.post(BOOKINGS_BASE, body: body, headers: headers)
      puts "failed to create parking booking: #{response.body}" unless response.success?
      response.status_code.should eq(201)

      created = JSON.parse(response.body).as_h
      {created["id"].as_i64, first_day}
    end

    # the wed/thu/fri occurrences over the following fortnight
    parking_instances = ->(booking_id : Int64, first_day : Time) do
      Booking.find(booking_id)
        .calculate_daily(first_day + 1.day, first_day + 14.days)
        .instances.map(&.to_unix)
    end

    list_parking = ->(first_day : Time) do
      route = "#{BOOKINGS_BASE}/?period_start=#{(first_day - 1.day).to_unix}" \
              "&period_end=#{(first_day + 14.days).to_unix}" \
              "&type=parking&zones=#{EXT_DATA_ZONES.first}"
      response = client.get(route, headers: headers)
      response.success?.should be_true
      JSON.parse(response.body).as_a.map(&.as_h)
    end

    it "returns the extension data on every occurrence of the series" do
      stub_engine.call

      booking_id, first_day = create_parking.call
      listed = list_parking.call(first_day)
      listed.size.should be > 1

      listed.each do |occurrence|
        occurrence["extension_data"]["plate_number"].should eq("testplate1"),
          "occurrence #{occurrence["instance"]?} has extension_data #{occurrence["extension_data"]}"
      end
    end

    it "keeps the extension data when only asset_id is sent for one occurrence" do
      stub_engine.call

      booking_id, first_day = create_parking.call
      instances = parking_instances.call(booking_id, first_day)
      instances.size.should be > 1
      instance = instances.first

      # the allocation only names the bay -- no asset_ids in the body
      response = client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {asset_id: "parking-bay-7"}.to_json,
      )
      puts "failed to allocate bay: #{response.body}" unless response.success?
      response.success?.should be_true

      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["asset_id"].should eq("parking-bay-7")
      shown["extension_data"]["plate_number"].should eq("testplate1")
      shown["extension_data"]["location"].should eq("Test Street")

      listed = list_parking.call(first_day)
      listed.each do |occurrence|
        occurrence["extension_data"]["plate_number"].should eq("testplate1"),
          "occurrence #{occurrence["instance"]?} has extension_data #{occurrence["extension_data"]}"
      end
    end

    it "keeps the extension data when asset_id is sent with an empty asset_ids" do
      stub_engine.call

      booking_id, first_day = create_parking.call
      instance = parking_instances.call(booking_id, first_day).first

      response = client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {asset_id: "parking-bay-7", asset_ids: [] of String}.to_json,
      )
      puts "failed to allocate bay: #{response.body}" unless response.success?
      response.success?.should be_true

      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["extension_data"]["plate_number"].should eq("testplate1")
      shown["extension_data"]["location"].should eq("Test Street")

      listed = list_parking.call(first_day)
      listed.each do |occurrence|
        occurrence["extension_data"]["plate_number"].should eq("testplate1"),
          "occurrence #{occurrence["instance"]?} has extension_data #{occurrence["extension_data"]}"
      end
    end

    it "still inherits later parent extension data changes on an occurrence whose asset changed" do
      stub_engine.call

      booking_id, first_day = create_parking.call
      instance = parking_instances.call(booking_id, first_day).first

      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {asset_id: "parking-bay-7"}.to_json,
      ).success?.should be_true

      stored = PlaceOS::Model::BookingInstance
        .where(id: booking_id, instance_start: instance)
        .first
      stored.extension_data.try(&.as_h?).should be_nil

      # now update the extension data on the parent series
      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/ext_data",
        headers: headers,
        body: {location: "Second Street"}.to_json,
      ).success?.should be_true

      # the occurrence that was re-allocated must not be stuck on a stale snapshot
      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["asset_id"].should eq("parking-bay-7")
      shown["extension_data"]["location"].should eq("Second Street")
      shown["extension_data"]["plate_number"].should eq("testplate1")
    end

    it "picks up the series' extension data on an occurrence re-allocated before any was set" do
      stub_engine.call

      # a series created without extension data
      first_day = Time.local(perth).at_beginning_of_day + 1.day
      response = client.post(BOOKINGS_BASE, headers: headers, body: {
        asset_id:            "unallocated-Ez15vtMs",
        zones:               EXT_DATA_ZONES,
        booking_start:       (first_day + 7.hours).to_unix,
        booking_end:         (first_day + 17.hours + 30.minutes).to_unix,
        booking_type:        "parking",
        timezone:            "Australia/Perth",
        recurrence_type:     "daily",
        recurrence_days:     0b1111111,
        recurrence_interval: 1,
        recurrence_end:      (first_day + 21.days).to_unix,
      }.to_json)
      puts "failed to create booking: #{response.body}" unless response.success?
      response.status_code.should eq(201)
      booking_id = JSON.parse(response.body).as_h["id"].as_i64

      instance = Booking.find(booking_id)
        .calculate_daily(first_day + 1.day, first_day + 14.days)
        .instances.map(&.to_unix).first

      # allocate a bay to one occurrence *before* any extension data exists
      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}",
        headers: headers,
        body: {asset_id: "parking-bay-7"}.to_json,
      ).success?.should be_true

      # the series then gets its extension data
      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/ext_data",
        headers: headers,
        body: PARKING_EXT_DATA.to_json,
      ).success?.should be_true

      # the re-allocated occurrence must not be stranded on an empty snapshot
      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["asset_id"].should eq("parking-bay-7")
      shown["extension_data"]["plate_number"].should eq("testplate1")
      shown["extension_data"]["location"].should eq("Test Street")
    end

    it "snapshots all effective data when an occurrence's extension data changes" do
      stub_engine.call

      booking_id, first_day = create_parking.call
      instance = parking_instances.call(booking_id, first_day).first

      # this occurrence gets its own plate number
      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/ext_data/#{instance}",
        headers: headers,
        body: {plate_number: "testplate2"}.to_json,
      ).success?.should be_true

      stored = PlaceOS::Model::BookingInstance
        .where(id: booking_id, instance_start: instance)
        .first.extension_data.not_nil!.as_h
      stored.keys.sort!.should eq(PARKING_EXT_DATA.keys.sort!)
      stored["plate_number"].should eq("testplate2")
      stored["location"].should eq("Test Street")

      # the series later changes a different key
      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/ext_data",
        headers: headers,
        body: {location: "Second Street"}.to_json,
      ).success?.should be_true

      shown = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      shown["extension_data"]["plate_number"].should eq("testplate2")
      shown["extension_data"]["location"].should eq("Test Street")

      # siblings continue inheriting from the parent series
      sibling = parking_instances.call(booking_id, first_day)[1]
      other = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{sibling}", headers: headers).body).as_h
      other["extension_data"]["plate_number"].should eq("testplate1")
      other["extension_data"]["location"].should eq("Second Street")
    end

    it "keeps inheriting when the instance extension-data route receives an empty object" do
      stub_engine.call

      booking_id, first_day = create_parking.call
      instance = parking_instances.call(booking_id, first_day).first

      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/ext_data/#{instance}",
        headers: headers,
        body: ({} of String => JSON::Any).to_json,
      ).success?.should be_true

      PlaceOS::Model::BookingInstance
        .where(id: booking_id, instance_start: instance)
        .first?.should be_nil

      client.patch(
        "#{BOOKINGS_BASE}/#{booking_id}/ext_data",
        headers: headers,
        body: {location: "Second Street"}.to_json,
      ).success?.should be_true

      inherited = JSON.parse(client.get("#{BOOKINGS_BASE}/#{booking_id}/instance/#{instance}", headers: headers).body).as_h
      inherited["extension_data"]["location"].should eq("Second Street")
    end
  end
end
