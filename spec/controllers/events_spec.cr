require "../spec_helper"
require "./helpers/spec_clean_up"

describe Events do
  systems_json = File.read("./spec/fixtures/placeos/systems.json")
  systems_resp = Array(JSON::Any).from_json(systems_json).map &.to_json

  describe "#index" do
    pending "#index should return a list of events with metadata" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=z1")
        .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/$batch")
        .to_return(body: File.read("./spec/fixtures/events/o365/batch_index.json"))

      now = 1588407645
      later = 1588422097
      event_start = 1598832000.to_i64
      event_end = 1598833800.to_i64
      id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA="
      system_id = "sys-rJQQlR4Cn7"
      room_email = "room1@example.com"
      host = "dev@acaprojects.onmicrosoft.com"

      body = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}?zone_ids=z1&period_start=#{now}&period_end=#{later}", headers: Mock::Headers.office365_guest) { |e|
        tenant_id = e.tenant.id
        EventMetadatasHelper.create_event(tenant_id, id, event_start, event_end, system_id, room_email, host)
        e.index
      }[1].as_a

      body.should contain(EventsHelper.mock_event(id, event_start, event_end, system_id, room_email, host, {"foo" => 123}))
    end

    pending "#index should return a list of events with metadata of master event if event in list is an occurrence" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=z1")
        .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/$batch")
        .to_return(body: File.read("./spec/fixtures/events/o365/batch_index_with_recurring_event.json"))

      now = 1588407645
      later = 1588422097
      event_start = 1598832000.to_i64
      event_end = 1598833800.to_i64
      master_event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA="
      system_id = "sys-rJQQlR4Cn7"
      room_email = "room1@example.com"
      host = "dev@acaprojects.onmicrosoft.com"

      body = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}?zone_ids=z1&period_start=#{now}&period_end=#{later}", headers: Mock::Headers.office365_guest) { |e|
        tenant_id = e.tenant.id
        EventMetadatasHelper.create_event(tenant_id, master_event_id, event_start, event_end, system_id, room_email, host)
        e.index
      }[1].as_a

      expected_result = EventsHelper.mock_event("event_instance_of_recurrence_id", event_start, event_end, system_id, room_email, host, {"foo" => 123})
      expected_result["recurring_event_id"] = master_event_id
      expected_result["recurring_master_id"] = master_event_id

      body.should contain(expected_result)
    end
  end

  describe "#create & #update" do
    pending "#create should create event with attendees and extension data and #update should update for system" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events/")
        .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))

      req_body = EventsHelper.create_event_input

      created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", body: req_body, headers: Mock::Headers.office365_guest, &.create)[1].as_h
      created_event.should eq(EventsHelper.create_event_output)

      # Should have created metadata record
      evt_meta = EventMetadata.query.find! { event_id == created_event["id"] }
      evt_meta.event_start.should eq(1598503500)
      evt_meta.event_end.should eq(1598507160)
      evt_meta.system_id.should eq("sys-rJQQlR4Cn7")
      evt_meta.host_email.should eq("dev@acaprojects.onmicrosoft.com")
      evt_meta.ext_data.not_nil!.as_h.should eq({"foo" => "bar"})

      # Should have created attendees records
      # 2 guests + 1 host
      evt_meta.attendees.count.should eq(3)

      # Should have created guests records
      guests = evt_meta.attendees.map(&.guest)
      guests.map(&.name).should eq(["Amit", "John", "dev@acaprojects.onmicrosoft.com"])
      guests.compact_map(&.email).should eq(["amit@redant.com.au", "jon@example.com", "dev@acaprojects.onmicrosoft.com"])
      guests.compact_map(&.preferred_name).should eq(["Jon"])
      guests.compact_map(&.phone).should eq(["012334446"])
      guests.compact_map(&.organisation).should eq(["Google inc"])
      guests.compact_map(&.notes).should eq(["some notes"])
      guests.compact_map(&.photo).should eq(["http://example.com/first.jpg"])
      guests.compact_map(&.searchable).should eq(["amit  ", "john jon google inc", "dev@acaprojects.onmicrosoft.com  "])
      guests.compact_map(&.ext_data).should eq([{} of String => String?, {"fizz" => "buzz"}, {} of String => String?])

      # Update

      req_body = EventsHelper.update_event_input

      updated_event = Context(Events, JSON::Any).response("PATCH", "#{EVENTS_BASE}/#{created_event["id"]}?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s}, body: req_body, headers: Mock::Headers.office365_guest, &.update)[1].as_h
      updated_event.should eq(EventsHelper.update_event_output)

      # Should have updated metadata record
      evt_meta = EventMetadata.query.find! { event_id == updated_event["id"] }
      evt_meta.event_start.should eq(1598504460)
      evt_meta.event_end.should eq(1598508120)

      # Should still have 3 created attendees records
      # 2 guests + 1 host
      evt_meta.attendees.count.should eq(3)

      # Should have updated guests records
      guests = evt_meta.attendees.map(&.guest)
      guests.map(&.name).should eq(["Amit", "dev@acaprojects.onmicrosoft.com", "Robert"])
      guests.compact_map(&.email).should eq(["amit@redant.com.au", "dev@acaprojects.onmicrosoft.com", "bob@example.com"])
      guests.compact_map(&.preferred_name).should eq(["bob"])
      guests.compact_map(&.phone).should eq(["012333336"])
      guests.compact_map(&.organisation).should eq(["Apple inc"])
      guests.compact_map(&.notes).should eq(["some updated notes"])
      guests.compact_map(&.photo).should eq(["http://example.com/bob.jpg"])
      guests.compact_map(&.ext_data).should eq([{"fuzz" => "bizz"}, {} of String => String?, {"buzz" => "fuzz"}])
    end

    pending "#create should create event with attendees and extension data and #update should extension data for when guest" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/jon@example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      req_body = EventsHelper.create_event_input
      created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", body: req_body, headers: Mock::Headers.office365_guest, &.create)[1].as_h

      # Guest Update
      req_body = EventsHelper.update_event_input
      updated_event = Context(Events, JSON::Any).response("PATCH", "#{EVENTS_BASE}/#{created_event["id"]}?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s}, body: req_body, headers: Mock::Headers.office365_guest(created_event["id"].to_s, "sys-rJQQlR4Cn7"), &.update)[1].as_h

      # Should have only updated extension in metadata record
      evt_meta = EventMetadata.query.find! { event_id == updated_event["id"] }
      evt_meta.event_start.should eq(1598503500)                      # unchanged event start
      evt_meta.event_end.should eq(1598507160)                        # unchanged event end
      evt_meta.ext_data.should eq({"foo" => "bar", "fizz" => "buzz"}) # updated event extension
    end

    pending "#create should create event and #update should update for user calendar" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events/")
        .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))

      req_body = EventsHelper.create_event_input

      created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", body: req_body, headers: Mock::Headers.office365_guest, &.create)[1].as_h

      # Update
      req_body = EventsHelper.update_event_input
      status_code, event = Context(Events, JSON::Any).response("PATCH", "#{EVENTS_BASE}/#{created_event["id"]}?calendar=dev@acaprojects.com", route_params: {"id" => created_event["id"].to_s}, body: req_body, headers: Mock::Headers.office365_guest, &.update)

      status_code.should eq(200)
      event.as_h["event_start"].should eq(1598504460)
      event.as_h["event_end"].should eq(1598508120)
    end
  end

  describe "#show" do
    pending "should return details for event with guest access" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/jon@example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      # Create event

      req_body = EventsHelper.create_event_input

      created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)[1].as_h

      # Fetch guest event details
      status_code, event = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{created_event["id"]}", route_params: {"id" => created_event["id"].to_s}, headers: Mock::Headers.office365_guest(created_event["id"].to_s, "sys-rJQQlR4Cn7"), &.show)

      status_code.should eq(200)
      event.as_h["event_start"].should eq(1598503500)
      event.as_h["event_end"].should eq(1598507160)
    end

    pending "should return details for event with guest access and event is recurring instance" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/jon@example.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      # Create event which will create metadata with id that we'll use as seriesMasterId

      req_body = EventsHelper.create_event_input
      Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)

      # Fetch guest event details that is an instance of master event created above
      event_instance_id = "event_instance_of_recurrence_id"
      status_code, event = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{event_instance_id}", route_params: {"id" => event_instance_id}, headers: Mock::Headers.office365_guest(event_instance_id, "sys-rJQQlR4Cn7"), &.show)

      status_code.should eq(200)
      master_event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA="

      # Metadata should not exist for this event
      EventMetadata.query.find({event_id: event_instance_id}).should eq(nil)
      event.as_h["event_start"].should eq(1598503500)
      event.as_h["event_end"].should eq(1598507160)
      event.as_h["recurring_master_id"].should eq(master_event_id)
      # Should have extension data stored on master event
      event.as_h["extension_data"].should eq({"foo" => "bar"})
    end

    pending "should return details for event with normal access" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

      # Create event

      req_body = EventsHelper.create_event_input
      created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)[1].as_h

      # Show for calendar
      status_code, event = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{created_event["id"]}?calendar=dev@acaprojects.com", route_params: {"id" => created_event["id"].to_s}, headers: Mock::Headers.office365_guest, &.show)

      status_code.should eq(200)
      event.as_h["event_start"].should eq(1598503500)
      event.as_h["event_end"].should eq(1598507160)

      # Show for room
      status_code, event = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{created_event["id"]}?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s}, headers: Mock::Headers.office365_guest, &.show)
      status_code.should eq(200)
      event.as_h["event_start"].should eq(1598503500)
      event.as_h["event_end"].should eq(1598507160)
    end

    pending "should return details for event that is an recurring event instance with normal access" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))

      # Create event which will create metadata with id that we'll use as seriesMasterId

      req_body = EventsHelper.create_event_input
      Events.context("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)

      event_instance_id = "event_instance_of_recurrence_id"
      # Metadata should not exist for this event
      EventMetadata.query.find({event_id: event_instance_id}).should eq(nil)

      master_event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA="

      # Show event details for calendar params that is an instance of master event created above
      status_code, event = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{event_instance_id}?calendar=dev@acaprojects.com", route_params: {"id" => event_instance_id}, headers: Mock::Headers.office365_guest, &.show)
      status_code.should eq(200)
      event.as_h["event_start"].should eq(1598503500)
      event.as_h["event_end"].should eq(1598507160)
      event.as_h["recurring_master_id"].should eq(master_event_id)
      # Should not have any exetension information
      event.as_h["extension_data"]?.should eq(nil)

      # Show event details for room/system params that is an instance of master event created above
      status_code, event = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{event_instance_id}?system_id=sys-rJQQlR4Cn7", route_params: {"id" => event_instance_id}, headers: Mock::Headers.office365_guest, &.show)

      status_code.should eq(200)
      event.as_h["event_start"].should eq(1598503500)
      event.as_h["event_end"].should eq(1598507160)
      event.as_h["recurring_master_id"].should eq(master_event_id)
      # Should have extension data stored on master event
      event.as_h["extension_data"].should eq({"foo" => "bar"})
    end
  end

  pending "#destroy the event for system" do
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
      WebMock
        .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
        .to_return(body: systems_resp[index])
    end
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:delete, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: "")

    # Create event

    req_body = EventsHelper.create_event_input
    created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)[1].as_h

    # Should have created event meta
    EventMetadata.query.find { event_id == created_event["id"] }.should_not eq(nil)

    # delete
    Events.context("DELETE", "#{EVENTS_BASE}/#{created_event["id"]}?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s}, headers: Mock::Headers.office365_guest, &.destroy)

    # Should have deleted event meta
    EventMetadata.query.find { event_id == created_event["id"] }.should eq(nil)
  end

  pending "#approve marks room as accepted" do
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
      WebMock
        .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
        .to_return(body: systems_resp[index])
    end
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/update_with_accepted.json"))

    # Create event

    req_body = EventsHelper.create_event_input

    created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)[1].as_h

    # approve
    accepted_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{created_event["id"]}/approve?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s}, headers: Mock::Headers.office365_guest, &.approve)[1].as_h

    room_attendee = accepted_event["attendees"].as_a.find { |a| a["email"] == "rmaudpswissalps@booking.demo.acaengine.com" }
    room_attendee.not_nil!["response_status"].as_s.should eq("accepted")
  end

  pending "#reject marks room as declined" do
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
      WebMock
        .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
        .to_return(body: systems_resp[index])
    end
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/update_with_declined.json"))

    # Create event
    req_body = EventsHelper.create_event_input
    created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)[1].as_h

    # reject
    declined_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{created_event["id"]}/reject?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s}, headers: Mock::Headers.office365_guest, &.approve)[1].as_h
    room_attendee = declined_event["attendees"].as_a.find { |a| a["email"] == "rmaudpswissalps@booking.demo.acaengine.com" }
    room_attendee.not_nil!["response_status"].as_s.should eq("declined")
  end

  describe "#guest_list" do
    pending "lists guests for an event & guest_checkin checks them in" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/jon@example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/checkin")
        .to_return(body: "")

      # Create event

      req_body = EventsHelper.create_event_input
      created_event = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)[1].as_h

      # guest_list
      guests = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{created_event["id"]}/guests?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s}, headers: Mock::Headers.office365_guest, &.guest_list)[1].as_a
      guests.should eq(EventsHelper.guests_list_output)

      # guest_checkin via system
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{created_event["id"]}/guests/jon@example.com/checkin?system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest, &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(true)

      # guest_checkin via system state = false
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{created_event["id"]}/guests/jon@example.com/checkin?state=false&system_id=sys-rJQQlR4Cn7", route_params: {"id" => created_event["id"].to_s, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest, &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(false)

      # guest_checkin via guest_token
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{created_event["id"]}/guests/jon@example.com/checkin", route_params: {"id" => created_event["id"].to_s, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest(created_event["id"].to_s, "sys-rJQQlR4Cn7"), &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(true)

      # guest_checkin via guest_token state = false
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{created_event["id"]}/guests/jon@example.com/checkin?state=false", route_params: {"id" => created_event["id"].to_s, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest(created_event["id"].to_s, "sys-rJQQlR4Cn7"), &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(false)
    end

    pending "lists guests for an event that is an recurring instance & guest_checkin checks them in" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
      {"sys-rJQQlR4Cn7"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
        .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
        .to_return(body: "")
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
        .to_return(body: "")
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/jon@example.com/calendar/events/event_instance_of_recurrence_id")
        .to_return(body: File.read("./spec/fixtures/events/o365/show_recurring.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/checkin")
        .to_return(body: "")

      # Create event which will create metadata with id that we'll use as seriesMasterId

      req_body = EventsHelper.create_event_input
      Events.context("POST", "#{EVENTS_BASE}/", headers: Mock::Headers.office365_guest, body: req_body, &.create)

      event_instance_id = "event_instance_of_recurrence_id"
      # Metadata should not exist for this event
      EventMetadata.query.find({event_id: event_instance_id}).should eq(nil)

      # guest_list
      guests = Context(Events, JSON::Any).response("GET", "#{EVENTS_BASE}/#{event_instance_id}/guests?system_id=sys-rJQQlR4Cn7", route_params: {"id" => event_instance_id}, headers: Mock::Headers.office365_guest, &.guest_list)[1].as_a
      guests.should eq(EventsHelper.guests_list_output)

      # guest_checkin via system
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin?system_id=sys-rJQQlR4Cn7", route_params: {"id" => event_instance_id, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest, &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(true)

      # We should have created meta by migrating from master event meta
      meta_after_checkin = EventMetadata.query.find!({event_id: event_instance_id})
      master_event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA="
      master_meta = EventMetadata.query.find!({event_id: master_event_id})
      meta_after_checkin.ext_data.should eq(master_meta.ext_data)
      meta_after_checkin.attendees.count.should eq(master_meta.attendees.count)

      # guest_checkin via system state = false
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin?state=false&system_id=sys-rJQQlR4Cn7", route_params: {"id" => event_instance_id, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest, &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(false)

      # guest_checkin via guest_token
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin", route_params: {"id" => event_instance_id, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest(event_instance_id, "sys-rJQQlR4Cn7"), &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(true)

      # guest_checkin via guest_token state = false
      checked_in_guest = Context(Events, JSON::Any).response("POST", "#{EVENTS_BASE}/#{event_instance_id}/guests/jon@example.com/checkin?state=false", route_params: {"id" => event_instance_id, "guest_id" => "jon@example.com"}, headers: Mock::Headers.office365_guest(event_instance_id, "sys-rJQQlR4Cn7"), &.guest_checkin)[1].as_h
      checked_in_guest["checked_in"].should eq(false)
    end
  end
end

EVENTS_BASE = Events.base_route

module EventsHelper
  extend self

  def mock_event(id, event_start, event_end, system_id, room_email, host, ext_data)
    {
      "event_start" => event_start,
      "event_end"   => event_end,
      "id"          => id,
      "host"        => host,
      "title"       => "My new meeting",
      "body"        => "The quick brown fox jumps over the lazy dog",
      "attendees"   => [{"name" => "Toby Carvan",
                       "email" => "testing@redant.com.au",
                       "response_status" => "needsAction",
                       "resource" => false,
                       "extension_data" => {} of String => String?,
      },
      {"name"            => "Amit Gaur",
       "email"           => "amit@redant.com.au",
       "response_status" => "needsAction",
       "resource"        => false,
       "extension_data"  => {} of String => String?,
      },
      ],
      "location"    => "",
      "private"     => true,
      "all_day"     => false,
      "timezone"    => "Australia/Sydney",
      "recurring"   => false,
      "attachments" => [] of String,
      "status"      => "confirmed",
      "creator"     => "dev@acaprojects.onmicrosoft.com",
      "calendar"    => "room1@example.com",
      "system"      => {"created_at" => 1562041110,
                   "updated_at" => 1562041120,
                   "id" => system_id,
                   "name" => "Room 1",
                   "zones" => ["zone-rGhCRp_aUD"],
                   "modules" => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"],
                   "email" => room_email,
                   "capacity" => 10,
                   "features" => [] of String,
                   "bookable" => true,
                   "installed_ui_devices" => 0,
                   "version" => 5},
      "extension_data" => ext_data,
    }
  end

  def create_event_input
    %({
    "event_start": 1598503500,
    "event_end": 1598507160,
    "attendees": [
         {
            "name": "Amit",
            "email": "amit@redant.com.au",
            "response_status": "accepted",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true
        },
        {
            "name": "John",
            "preferred_name": "Jon",
            "phone": "012334446",
            "organisation": "Google inc",
            "photo": "http://example.com/first.jpg",
            "email": "jon@example.com",
            "response_status": "tentative",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true,
            "extension_data": {
                "fizz": "buzz"
            },
            "notes": "some notes"
        }
    ],
    "private": false,
    "all_day": false,
    "recurring": false,
    "host": "dev@acaprojects.onmicrosoft.com",
    "title": "tentative event response status and default timezone trial updated",
    "body": "yeehaw hiya",
    "location": "test",
    "system_id": "sys-rJQQlR4Cn7",
    "system": {
        "id": "sys-rJQQlR4Cn7"
    },
    "extension_data": {
      "foo": "bar"
    }
    })
  end

  def update_event_input
    %({
    "event_start": 1598504460,
    "event_end": 1598508120,
    "attendees": [
         {
            "name": "Amit",
            "email": "amit@redant.com.au",
            "response_status": "accepted",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true,
            "extension_data": {
                "fuzz": "bizz"
            }
        },
        {
            "name": "Robert",
            "preferred_name": "bob",
            "phone": "012333336",
            "organisation": "Apple inc",
            "photo": "http://example.com/bob.jpg",
            "email": "bob@example.com",
            "response_status": "tentative",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true,
            "extension_data": {
                "buzz": "fuzz"
            },
            "notes": "some updated notes"
        }
    ],
    "private": false,
    "all_day": false,
    "recurring": false,
    "host": "dev@acaprojects.onmicrosoft.com",
    "title": "tentative event response status and default timezone trial",
    "body": "yeehaw hiya updated",
    "location": "test",
    "system_id": "sys-rJQQlR4Cn7",
    "system": {
        "id": "sys-rJQQlR4Cn7"
    },
    "extension_data": {
      "fizz": "buzz"
    }
    })
  end

  def create_event_output
    {"event_start" => 1598503500, "event_end" => 1598507160, "id" => "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=", "host" => "dev@acaprojects.onmicrosoft.com", "title" => "tentative event response status and default timezone trial updated", "body" => "yeehaw hiya", "attendees" => [{"name" => "Amit", "email" => "amit@redant.com.au", "response_status" => "accepted", "resource" => false, "checked_in" => false, "visit_expected" => true, "extension_data" => {} of String => String?}, {"name" => "John", "email" => "jon@example.com", "response_status" => "tentative", "resource" => false, "checked_in" => false, "visit_expected" => true, "extension_data" => {"fizz" => "buzz"}}, {"name" => "RM-AU-DP-L105-Swiss-Alps", "email" => "rmaudpswissalps@booking.demo.acaengine.com", "response_status" => "needsAction", "resource" => false, "extension_data" => {} of String => String?}, {"name" => "Developer", "email" => "dev@acaprojects.onmicrosoft.com", "response_status" => "accepted", "resource" => false, "checked_in" => false, "visit_expected" => true, "extension_data" => {} of String => String?}], "location" => "", "private" => true, "all_day" => false, "timezone" => "Australia/Sydney", "recurring" => false, "attachments" => [] of String, "status" => "confirmed", "creator" => "dev@acaprojects.onmicrosoft.com", "calendar" => "room1@example.com", "system" => {"created_at" => 1562041110, "updated_at" => 1562041120, "id" => "sys-rJQQlR4Cn7", "name" => "Room 1", "zones" => ["zone-rGhCRp_aUD"], "modules" => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"], "email" => "room1@example.com", "capacity" => 10, "features" => [] of String, "bookable" => true, "installed_ui_devices" => 0, "version" => 5}, "extension_data" => {"foo" => "bar"}}
  end

  def update_event_output
    {
      "event_start" => 1598504460,
      "event_end"   => 1598508120,
      "id"          => "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=",
      "host"        => "dev@acaprojects.onmicrosoft.com",
      "title"       => "tentative event response status and default timezone trial",
      "body"        => "yeehaw hiya updated",
      "attendees"   => [
        {"name"            => "Amit",
         "email"           => "amit@redant.com.au",
         "response_status" => "accepted",
         "resource"        => false,
         "checked_in"      => false,
         "visit_expected"  => true,
         "extension_data"  => {
           "fuzz" => "bizz",
         },
        },
        {"name"            => "Robert",
         "email"           => "bob@example.com",
         "response_status" => "tentative",
         "resource"        => false,
         "checked_in"      => false,
         "visit_expected"  => true,
         "extension_data":    {
           "buzz" => "fuzz",
         },
        },
        {"name"            => "RM-AU-DP-L105-Swiss-Alps",
         "email"           => "rmaudpswissalps@booking.demo.acaengine.com",
         "response_status" => "needsAction",
         "resource"        => false,
         "extension_data"  => {} of String => String?,
        },
        {"name"            => "Developer",
         "email"           => "dev@acaprojects.onmicrosoft.com",
         "response_status" => "accepted",
         "resource"        => false,
         "checked_in"      => false,
         "visit_expected"  => true,
         "extension_data"  => {} of String => String?,
        },
      ],
      "location"    => "",
      "private"     => true,
      "all_day"     => false,
      "timezone"    => "Australia/Sydney",
      "recurring"   => false,
      "attachments" => [] of String,
      "status"      => "confirmed",
      "creator"     => "dev@acaprojects.onmicrosoft.com",
      "calendar"    => "room1@example.com",
      "system"      => {"created_at" => 1562041110,
                   "updated_at" => 1562041120,
                   "id" => "sys-rJQQlR4Cn7",
                   "name" => "Room 1",
                   "zones" => ["zone-rGhCRp_aUD"],
                   "modules" => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"],
                   "email" => "room1@example.com",
                   "capacity" => 10,
                   "features" => [] of String,
                   "bookable" => true,
                   "installed_ui_devices" => 0,
                   "version" => 5},
      "extension_data" => {"foo" => "bar", "fizz" => "buzz"},
    }
  end

  def guests_list_output
    [{"email"          => "amit@redant.com.au",
      "name"           => "Amit",
      "preferred_name" => nil,
      "phone"          => nil,
      "organisation"   => nil,
      "notes"          => nil,
      "photo"          => nil,
      "banned"         => false,
      "dangerous"      => false,
      "extension_data" => {} of String => String?,
      "checked_in"     => false,
      "visit_expected" => true},
    {"email"          => "jon@example.com",
     "name"           => "John",
     "preferred_name" => "Jon",
     "phone"          => "012334446",
     "organisation"   => "Google inc",
     "notes"          => "some notes",
     "photo"          => "http://example.com/first.jpg",
     "banned"         => false,
     "dangerous"      => false,
     "extension_data" => {"fizz" => "buzz"},
     "checked_in"     => false,
     "visit_expected" => true},
    {"email"          => "dev@acaprojects.onmicrosoft.com",
     "name"           => "dev@acaprojects.onmicrosoft.com",
     "preferred_name" => nil,
     "phone"          => nil,
     "organisation"   => nil,
     "notes"          => nil,
     "photo"          => nil,
     "banned"         => false,
     "dangerous"      => false,
     "extension_data" => {} of String => String?,
     "checked_in"     => false,
     "visit_expected" => true}]
  end
end
