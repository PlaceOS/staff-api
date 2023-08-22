require "../spec_helper"
require "./helpers/event_helper"
require "./helpers/guest_helper"

EVENTS_BASE = Events.base_route

describe Events do
  before_each do
    EventMetadata.truncate
    Guest.truncate
    Attendee.truncate
    EventsHelper.stub_event_tokens
  end

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "#index should return a list of events with metadata" do
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=z1")
        .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/%24batch")
        .to_return(body: File.read("./spec/fixtures/events/o365/batch_index.json"))

      tenant = get_tenant
      event = EventMetadatasHelper.create_event(tenant.id)

      body = JSON.parse(client.get("#{EVENTS_BASE}?zone_ids=z1&period_start=#{event.event_start}&period_end=#{event.event_end}", headers: headers).body).as_a

      body.includes?(event.system_id)
      body.includes?(%("host" => "#{event.host_email}"))
      body.includes?(%("id" => "#{event.system_id}"))
      body.includes?(%("extension_data" => {#{event.ext_data}}))
    end

    it "metadata extension endpoint should filter by extension data" do
      WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=z1")
        .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/%24batch")
        .to_return(body: File.read("./spec/fixtures/events/o365/batch_index.json"))

      tenant = get_tenant

      EventMetadatasHelper.create_event(tenant.id, ext_data: JSON.parse({"colour": "blue"}.to_json))
      EventMetadatasHelper.create_event(tenant.id)
      EventMetadatasHelper.create_event(tenant.id, ext_data: JSON.parse({"colour": "red"}.to_json))

      field_name = "colour"
      value = "blue"

      body = JSON.parse(client.get("#{EVENTS_BASE}/extension_metadata?field_name=#{field_name}&value=#{value}", headers: headers).body)
      body.to_s.includes?("red").should be_false
    end

    it "#index should return a list of events with metadata of master event if event in list is an occurrence" do
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=zone-EzcsmWbvUG6")
        .to_return(body: File.read("./spec/fixtures/placeos/systemJ.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/%24batch")
        .to_return(body: File.read("./spec/fixtures/events/o365/batch_index_with_recurring_event.json"))

      now = 1.minutes.from_now.to_unix
      later = 80.minutes.from_now.to_unix
      master_event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA="

      tenant = get_tenant
      5.times { EventMetadatasHelper.create_event(tenant.id) }

      body = client.get("#{EVENTS_BASE}/?period_start=#{now}&period_end=#{later}", headers: headers).body
      body.includes?(%("recurring_master_id": "#{master_event_id}"))
    end
  end

  describe "#create" do
    before_each do
      EventsHelper.stub_create_endpoints
    end

    it "with attendees and extension data" do
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/")
        .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

      req_body = EventsHelper.create_event_input

      tenant = get_tenant
      event = EventMetadatasHelper.create_event(tenant.id)
      created_event = client.post(EVENTS_BASE, headers: headers, body: req_body).body
      created_event.includes?(%("event_start": #{event.event_start}))

      # Should have created metadata record
      evt_meta = EventMetadata.find_by(event_id: JSON.parse(created_event)["id"].as_s)
      evt_meta.event_start.should eq(1598503500)
      evt_meta.event_end.should eq(1598507160)
      evt_meta.system_id.should eq("sys-rJQQlR4Cn7")
      evt_meta.host_email.should eq("dev@acaprojects.onmicrosoft.com")
      evt_meta.ext_data.not_nil!.as_h.should eq({"foo" => "bar"})

      # Should have created attendees records
      # 2 guests + 1 host
      evt_meta.attendees.count.should eq(2)

      # Should have created guests records
      guests = evt_meta.attendees.map(&.guest.not_nil!)
      guests.map(&.name).should eq(["John", "dev@acaprojects.onmicrosoft.com"])
      guests.compact_map(&.email).should eq(["jon@example.com", "dev@acaprojects.onmicrosoft.com"])
      guests.compact_map(&.preferred_name).should eq(["Jon"])
      guests.compact_map(&.phone).should eq(["012334446"])
      guests.compact_map(&.organisation).should eq(["Google inc"])
      guests.compact_map(&.notes).should eq(["some notes"])
      guests.compact_map(&.photo).should eq(["http://example.com/first.jpg"])
      guests.compact_map(&.searchable).should eq(["jon@example.com john jon google inc 012334446", "dev@acaprojects.onmicrosoft.com dev@acaprojects.onmicrosoft.com   "])
      guests.compact_map(&.extension_data).should eq([{"fizz" => "buzz"}, {} of String => String?])
    end
  end

  describe "#update" do
    before_each do
      EventsHelper.stub_create_endpoints
    end

    it "for system" do
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
        .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

      # Stub getting the host event
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/calendarView?startDateTime=2020-08-26T14%3A00%3A00-00%3A00&endDateTime=2020-08-27T13%3A59%3A59-00%3A00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&%24top=10000")
        .to_return(body: File.read("./spec/fixtures/events/o365/events_query.json"))

      req_body = EventsHelper.create_event_input

      created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body).body).as_h
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/calendarView?startDateTime=2020-08-26T14:00:00-00:00&endDateTime=2020-08-27T13:59:59-00:00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&$top=10000")
        .to_return(EventsHelper.event_query_response(created_event_id))

      req_body = EventsHelper.update_event_input
      system_id = "sys-rJQQlR4Cn7"
      EventsHelper.stub_permissions_check(system_id)
      updated_event = client.patch("#{EVENTS_BASE}/#{created_event["id"]}?system_id=#{system_id}", headers: headers, body: req_body).body
      updated_event.includes?(%(some updated notes))
      # .should eq(EventsHelper.update_event_output)
      # Should have updated metadata record
      evt_meta = EventMetadata.find_by(event_id: JSON.parse(updated_event)["id"].as_s)
      evt_meta.event_start.should eq(1598504460)
      evt_meta.event_end.should eq(1598508120)

      # Should still have 3 created attendees records
      # 2 guests + 1 host
      evt_meta.attendees.count.should eq(3)

      # Should have updated guests records
      guests = evt_meta.attendees.map(&.guest.not_nil!)
      (guests.map(&.name) - ["Amit", "dev@acaprojects.onmicrosoft.com", "Robert"]).size.should eq(0)
      (guests.compact_map(&.email) - ["amit@redant.com.au", "dev@acaprojects.onmicrosoft.com", "bob@example.com"]).size.should eq(0)
      guests.compact_map(&.preferred_name).should eq(["bob"])
      guests.compact_map(&.phone).should eq(["012333336"])
      guests.compact_map(&.organisation).should eq(["Apple inc"])
      guests.compact_map(&.notes).should eq(["some updated notes"])
      guests.compact_map(&.photo).should eq(["http://example.com/bob.jpg"])
      (guests.compact_map(&.extension_data) - [{"fuzz" => "bizz"}, {} of String => String?, {"buzz" => "fuzz"}]).size.should eq(0)
    end

    pending "extension data for guest" do
      # TODO:: guests should use the dedicated metadata patch method
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/jon@example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/")
        .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

      # Stub getting the host event
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/calendarView?startDateTime=2020-08-26T14%3A00%3A00-00%3A00&endDateTime=2020-08-27T13%3A59%3A59-00%3A00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&%24top=10000")
        .to_return(body: File.read("./spec/fixtures/events/o365/events_query.json"))

      req_body = EventsHelper.create_event_input
      evt_resp = client.post(EVENTS_BASE, headers: headers, body: req_body)
      created_event = JSON.parse(evt_resp.body)
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/calendarView?startDateTime=2020-08-26T14:00:00-00:00&endDateTime=2020-08-27T13:59:59-00:00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&$top=10000")
        .to_return(EventsHelper.event_query_response(created_event_id))

      # Guest Update
      req_body = EventsHelper.update_event_input
      resp = client.patch("#{EVENTS_BASE}/#{created_event_id}?system_id=sys-rJQQlR4Cn7", headers: Mock::Headers.office365_guest(created_event_id, "sys-rJQQlR4Cn7"), body: req_body)
      body = resp.body
      updated_event = JSON.parse(body)

      # Should have only updated extension in metadata record
      evt_meta = EventMetadata.find_by(event_id: updated_event["id"].to_s)
      evt_meta.event_start.should eq(1598503500)                      # unchanged event start
      evt_meta.event_end.should eq(1598507160)                        # unchanged event end
      evt_meta.ext_data.should eq({"foo" => "bar", "fizz" => "buzz"}) # updated event extension
    end

    it "#for user calendar" do
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
        .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/calendarView?startDateTime=2020-08-26T14%3A00%3A00-00%3A00&endDateTime=2020-08-27T13%3A59%3A59-00%3A00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&%24top=10000")
        .to_return(body: File.read("./spec/fixtures/events/o365/events_query.json"))

      req_body = EventsHelper.create_event_input

      created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body).body)
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/calendarView?startDateTime=2020-08-26T14:00:00-00:00&endDateTime=2020-08-27T13:59:59-00:00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&$top=10000")
        .to_return(EventsHelper.event_query_response(created_event_id))

      # Update
      req_body = EventsHelper.update_event_input
      system_id = "sys-rJQQlR4Cn7"
      EventsHelper.stub_permissions_check(system_id)
      resp = client.patch("#{EVENTS_BASE}/#{created_event["id"]}?system_id=#{system_id}", headers: headers, body: req_body)

      updated_event = JSON.parse(resp.body)
      updated_event["event_start"].should eq(1598504460)
      updated_event["event_end"].should eq(1598508120)
    end
  end

  describe "#show" do
    before_each do
      EventsHelper.stub_show_endpoints
    end

    it "details for event with limited guest access" do
      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/events\/.*/)
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      # Create event
      req_body = EventsHelper.create_event_input

      created_event = JSON.parse(client.post(EVENTS_BASE, headers: Mock::Headers.office365_guest, body: req_body).body)
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
        .to_return(EventsHelper.event_query_response(created_event_id))

      # Fetch guest event details
      response = client.get("#{EVENTS_BASE}/#{created_event["id"]}", headers: Mock::Headers.office365_guest(created_event_id, "sys-rJQQlR4Cn7"))
      response.status_code.should eq(200)
      event = JSON.parse(response.body)

      event["event_start"].should eq(1598503500)
      event["event_end"].should eq(1598507160)
    end

    it "details for event with guest access and event is recurring instance" do
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      # Create event which will create metadata with id that we'll use as seriesMasterId

      req_body = EventsHelper.create_recurring_event_input
      created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body.to_s).body)
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
        .to_return(EventsHelper.event_query_response(created_event_id))

      # Fetch guest event details that is an instance of master event created above
      event_instance_id = "event_instance_of_recurrence_id"
      response = client.get("#{EVENTS_BASE}/#{event_instance_id}?system_id=sys-rJQQlR4Cn7", headers: Mock::Headers.office365_guest(created_event_id, "sys-rJQQlR4Cn7"))
      response.status_code.should eq(200)

      event = JSON.parse(response.body)
      master_event_id = created_event["id"].to_s

      # Metadata should not exist for this event
      EventMetadata.find_by?(event_id: event_instance_id).should be_nil
      event["event_start"].should eq(1598503500)
      event["event_end"].should eq(1598507160)
      # Should have extension data stored on master event
      evt_meta = EventMetadata.find_by(event_id: created_event_id)
      evt_meta.recurring_master_id.should eq(master_event_id)
      event["extension_data"].should eq({"foo" => "bar"})
    end

    it "details for event with normal access" do
      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/events\/?.*/)
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      # Create event

      req_body = EventsHelper.create_event_input
      created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body).body)
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
        .to_return(EventsHelper.event_query_response(created_event_id))

      # Show for calendar
      response = client.get("#{EVENTS_BASE}/#{created_event_id}?calendar=dev@acaprojects.onmicrosoft.com", headers: headers)
      response.status_code.should eq(200)
      event = JSON.parse(response.body)

      event["event_start"].should eq(1598503500)
      event["event_end"].should eq(1598507160)

      # Show for room
      response = client.get("#{EVENTS_BASE}/#{created_event_id}?system_id=sys-rJQQlR4Cn7", headers: headers)
      response.status_code.should eq(200)
      event = JSON.parse(response.body)
      event["event_start"].should eq(1598503500)
      event["event_end"].should eq(1598507160)
    end

    it "details for event that is an recurring event instance with normal access" do
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      # Create event which will create metadata with id that we'll use as seriesMasterId

      req_body = EventsHelper.create_event_input
      created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body).body)

      event_instance_id = "event_instance_of_recurrence_id"
      # Metadata should not exist for this event
      EventMetadata.find_by?(event_id: event_instance_id).should be_nil

      master_event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA="

      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/calendarView?startDateTime=2020-08-30T14:00:00-00:00&endDateTime=2020-08-31T13:59:59-00:00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000008CD0441F4E7FD60100000000000000001000000087A54520ECE5BD4AA552D826F3718E7F%27&$top=10000")
        .to_return(EventsHelper.event_query_response(created_event_id))

      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
        .to_return(EventsHelper.event_query_response(created_event_id))

      # Show event details for calendar params that is an instance of master event created above
      response = client.get("#{EVENTS_BASE}/#{event_instance_id}?calendar=dev@acaprojects.onmicrosoft.com", headers: headers)
      response.status_code.should eq(200)
      event = JSON.parse(response.body)
      event["event_start"].should eq(1598503500)
      event["event_end"].should eq(1598507160)

      evt_meta = EventMetadata.find_by(event_id: created_event_id)
      evt_meta.recurring_master_id.should eq(master_event_id)
      event["extension_data"]?.should eq({"foo" => "bar"})

      # Show event details for room/system params that is an instance of master event created above
      response = client.get("#{EVENTS_BASE}/#{event_instance_id}?system_id=sys-rJQQlR4Cn7", headers: headers)
      response.status_code.should eq(200)
      event_h = JSON.parse(response.body)

      event_h["event_start"].should eq(1598503500)
      event_h["event_end"].should eq(1598507160)

      # Should have extension data stored on master event
      event_h["extension_data"]?.should eq({"foo" => "bar"})
    end
  end

  it "#destroy the event for system" do
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

    WebMock.stub(:delete, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/events\/?.*/)
      .to_return(body: "")

    WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/events\/?.*/)
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

    # Create event
    req_body = EventsHelper.create_event_input
    created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body).body)
    created_event_id = created_event["id"].as_s
    system_id = created_event["system"]["id"].as_s

    WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
      .to_return(EventsHelper.event_query_response(created_event_id))

    # Should have created event meta
    metadata = EventMetadata.find_by?(event_id: created_event_id.to_s, system_id: system_id)
    metadata.should_not eq(nil)

    meta = metadata.not_nil!

    WebMock.stub(:get, "http://toby.dev.place.tech/api/engine/v2/metadata/sys-rJQQlR4Cn7?name=permissions")
      .to_return(body: %({"permissions":
      {"name":"permissions",
        "parent_id": "22",
        "description" : "grant access",
      "details":{"admin": ["admin"]}}}))

    WebMock.stub(:get, "http://toby.dev.place.tech/api/engine/v2/metadata/zone-rGhCRp_aUD?name=permissions")
      .to_return(body: %({"permissions":
         {"name":"permissions",
           "parent_id": "22",
           "description" : "grant access",
         "details":{"admin": ["admin"]}}}))

    # delete
    resp = client.delete("#{EVENTS_BASE}/#{created_event_id}?system_id=#{meta.try &.system_id}", headers: headers)
    resp.success?.should be_true

    # Should have deleted event meta
    EventMetadata.find_by?(event_id: created_event_id.to_s, system_id: system_id).should eq(nil)
  end

  it "#approve marks room as accepted" do
    EventsHelper.stub_create_endpoints

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

    # Create event

    req_body = EventsHelper.create_event_input

    created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body).body)
    created_event_id = created_event["id"].to_s
    WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
      .to_return(EventsHelper.event_query_response(created_event_id))

    WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D").to_return(body: File.read("./spec/fixtures/events/o365/update_with_accepted.json"))

    # ensure the user has permissions to update the event
    system_id = "sys-rJQQlR4Cn7"
    EventsHelper.stub_permissions_check(system_id)

    # approve
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D/accept")
      .to_return({sucess: true}.to_json)

    resp = client.post("#{EVENTS_BASE}/#{created_event["id"]}/approve?system_id=#{system_id}", headers: headers)
    resp.success?.should eq true
  end

  it "#reject marks room as declined" do
    EventsHelper.stub_create_endpoints

    WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/")
      .to_return(GuestsHelper.mock_event_query_json)

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

    # Create event
    req_body = EventsHelper.create_event_input
    evt_resp = client.post(EVENTS_BASE, headers: headers, body: req_body)
    created_event = JSON.parse(evt_resp.body)
    created_event_id = created_event["id"].to_s
    WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
      .to_return(EventsHelper.event_query_response(created_event_id))

    # reject
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D/decline")
      .to_return(body: {success: true}.to_json)

    system_id = "sys-rJQQlR4Cn7"
    EventsHelper.stub_permissions_check(system_id)
    resp = client.post("#{EVENTS_BASE}/#{created_event["id"]}/reject?system_id=#{system_id}", headers: headers)
    resp.success?.should eq true
  end

  describe "#guest_list" do
    it "lists guests for an event & guest_checkin checks them in" do
      EventsHelper.stub_create_endpoints

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/checkin")
        .to_return(body: "")

      # Create event

      req_body = EventsHelper.create_event_input
      created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body).body)
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
        .to_return(EventsHelper.event_query_response(created_event_id))

      # guest_list
      client.get("#{EVENTS_BASE}/#{created_event_id}/guests?system_id=sys-rJQQlR4Cn7", headers: headers)
      # guests.should eq(EventsHelper.guests_list_output)
      # guests.to_s.includes?(%("id" => "sys-rJQQlR4Cn7"))

      evt_meta = EventMetadata.find_by(event_id: created_event_id)
      guests = evt_meta.attendees.map(&.guest.not_nil!)
      guests.map(&.name).should eq(["John", "dev@acaprojects.onmicrosoft.com"])

      # guest_checkin via system
      resp = client.post("#{EVENTS_BASE}/#{created_event_id}/guests/jon@example.com/checkin?system_id=sys-rJQQlR4Cn7", headers: headers).body
      checked_in_guest = JSON.parse(resp)
      checked_in_guest["checked_in"].should eq(true)

      # guest_checkin via system state = false
      checked_in_guest = JSON.parse(client.post("#{EVENTS_BASE}/#{created_event_id}/guests/jon@example.com/checkin?state=false&system_id=sys-rJQQlR4Cn7", headers: headers).body)
      checked_in_guest["checked_in"].should eq(false)

      # guest_checkin via guest_token
      body = client.post("#{EVENTS_BASE}/#{created_event_id}/guests/jon@example.com/checkin?system_id=sys-rJQQlR4Cn7", headers: Mock::Headers.office365_guest(created_event_id, "sys-rJQQlR4Cn7")).body
      checked_in_guest = JSON.parse(body)
      checked_in_guest["checked_in"].should eq(true)

      # guest_checkin via guest_token state = false
      checked_in_guest = JSON.parse(client.post("#{EVENTS_BASE}/#{created_event_id}/guests/jon@example.com/checkin?state=false&system_id=sys-rJQQlR4Cn7", headers: Mock::Headers.office365_guest(created_event_id, "sys-rJQQlR4Cn7")).body)
      checked_in_guest["checked_in"].should eq(false)
    end

    pending "lists guests for an event that is an recurring instance & guest_checkin checks them in" do
      EventsHelper.stub_create_endpoints

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/checkin")
        .to_return(body: "")

      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_instance_recurring.json"))

      # Create event which will create metadata with id that we'll use as seriesMasterId

      req_body = EventsHelper.create_event_input

      created_event = JSON.parse(client.post(EVENTS_BASE, headers: headers, body: req_body.to_s).body)
      created_event_id = created_event["id"].to_s

      WebMock.stub(:get, /^https:\/\/graph\.microsoft\.com\/v1\.0\/users\/[^\/]*\/calendar\/calendarView\?.*/)
        .to_return(EventsHelper.event_query_response(created_event_id))

      event_instance_id = "event_instance_of_recurrence_id"
      # Metadata should not exist for this event
      EventMetadata.query.find({event_id: event_instance_id}).should eq(nil)

      # guest_list
      guests = client.get("#{EVENTS_BASE}/#{event_instance_id}/guests?system_id=sys-rJQQlR4Cn7", headers: headers).body
      guests.includes?(%("email": "amit@redant.com.au"))

      # guest_checkin via system
      checked_in_guest = JSON.parse client.post("#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin?system_id=sys-rJQQlR4Cn7", headers: headers).body
      checked_in_guest["checked_in"].should eq(true)

      # We should have created meta by migrating from master event meta
      meta_after_checkin = EventMetadata.query.find!({event_id: event_instance_id})
      master_event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA="
      master_meta = EventMetadata.query.find!({event_id: master_event_id})
      meta_after_checkin.ext_data.should eq(master_meta.ext_data)
      meta_after_checkin.attendees.count.should eq(master_meta.attendees.count)

      # guest_checkin via system state = false
      checked_in_guest = JSON.parse client.post("#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin?state=false&system_id=sys-rJQQlR4Cn7", headers: headers).body
      checked_in_guest["checked_in"].should eq(false)

      # guest_checkin via guest_token
      checked_in_guest = JSON.parse client.post("#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin", headers: Mock::Headers.office365_guest(event_instance_id, "sys-rJQQlR4Cn7")).body
      checked_in_guest["checked_in"].should eq(true)

      # guest_checkin via guest_token state = false
      checked_in_guest = JSON.parse client.post("#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin?state=false", headers: Mock::Headers.office365_guest(event_instance_id, "sys-rJQQlR4Cn7")).body
      checked_in_guest["checked_in"].should eq(false)
    end
  end

  describe "extension_data" do
    it "updates extension_data in the database" do
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/calendarView?startDateTime=2020-08-26T14%3A00%3A00-00%3A00&endDateTime=2020-08-27T13%3A59%3A59-00%3A00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&%24top=10000")
        .to_return(body: File.read("./spec/fixtures/events/o365/events_query.json"))

      tenant = get_tenant
      event = EventMetadatasHelper.create_event(
        tenant_id: tenant.id,
        id: "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=",
        event_start: 20.minutes.from_now.to_unix,
        event_end: 40.minutes.from_now.to_unix,
        system_id: "sys-rJQQlR4Cn7",
        room_email: "room1@example.com",
        ext_data: JSON.parse({"magic_number": 77}.to_json),
        ical_uid: "040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10"
      )

      update_body = {
        "count" => 2,
      }.to_json

      request = client.patch(
        "#{EVENTS_BASE}/#{event.event_id}/metadata/#{event.system_id}",
        headers: headers,
        body: update_body
      )
      request.status_code.should eq(200)

      request_body = JSON.parse(request.body)
      request_body["magic_number"].should eq(77)
      request_body["count"].should eq(2)

      db_event = EventMetadata.where(event_id: event.event_id).to_a.first
      db_event.ext_data.not_nil!["magic_number"].should eq(77)
      db_event.ext_data.not_nil!["count"].should eq(2)
    end

    it "returnes extension_data from the database" do
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/%24batch")
        .to_return(body: File.read("./spec/fixtures/events/o365/batch_index.json"))

      tenant = get_tenant
      event = EventMetadatasHelper.create_event(
        tenant_id: tenant.id,
        id: "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA=",
        event_start: 20.minutes.from_now.to_unix,
        event_end: 40.minutes.from_now.to_unix,
        system_id: "sys-rJQQlR4Cn7",
        room_email: "room1@example.com",
        ext_data: JSON.parse({"magic_number": 77}.to_json)
      )

      request = client.get("#{EVENTS_BASE}?period_start=#{event.event_start}&period_end=#{event.event_end}", headers: headers)
      request.status_code.should eq(200)

      request_body = JSON.parse(request.body)
      request_body[0]["extension_data"]["magic_number"].should eq(77)
    end
  end
end
