require "../spec_helper"

describe Events do
  Spec.after_each do
    Guest.query.each { |record| record.delete }
    Attendee.query.each { |record| record.delete }
    EventMetadata.query.each { |record| record.delete }
  end
  systems_json = File.read("./spec/fixtures/placeos/systems.json")
  systems_resp = Array(JSON::Any).from_json(systems_json).map &.to_json

  it "#index should return a list of events with metadata" do
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=z1")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/calendarView?startDateTime=2020-05-02T08:20:45-00:00&endDateTime=2020-05-02T12:21:37-00:00")
      .to_return(body: File.read("./spec/fixtures/events/o365/index.json"))

    now = 1588407645
    later = 1588422097

    response = IO::Memory.new
    events = Events.new(context("GET", "/api/staff/v1/events?zone_ids=z1&period_start=#{now}&period_end=#{later}", OFFICE365_HEADERS, response_io: response))

    event_start = 1598832000.to_i64
    event_end = 1598833800.to_i64
    id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA="
    system_id = "sys-rJQQlR4Cn7"
    room_email = "room1@example.com"
    host = "dev@acaprojects.onmicrosoft.com"
    tenant_id = events.tenant.id

    EventMetadatasHelper.create_event(tenant_id, id, event_start, event_end, system_id, room_email, host)

    events.index

    results = extract_json(response)

    results.as_a.should contain(EventsHelper.mock_event(id, event_start, event_end, system_id, room_email, host, {"foo" => 123}))
  end

  it "#create should create event with attendees and extension data and #update should update for system" do
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

    body = IO::Memory.new
    body << EventsHelper.create_event_input
    body.rewind
    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/events/", OFFICE365_HEADERS, body, response_io: response)
    Events.new(context).create
    created_event = extract_json(response).as_h

    created_event.should eq(EventsHelper.create_event_output)

    # Should have created metadata record
    evt_meta = EventMetadata.query.find { event_id == created_event["id"] }.not_nil!
    evt_meta.event_start.should eq(1598503500)
    evt_meta.event_end.should eq(1598507160)
    evt_meta.system_id.should eq("sys-rJQQlR4Cn7")
    evt_meta.host_email.should eq("dev@acaprojects.onmicrosoft.com")
    evt_meta.ext_data.not_nil!.as_h.should eq({"foo" => "bar"})

    # Should have created attendees records
    # 2 guests + 1 host
    evt_meta.attendees.count.should eq(3)

    # Should have created guests records
    guests = evt_meta.attendees.map { |a| a.guest }
    guests.map { |g| g.name }.should eq(["Amit", "John", "dev@acaprojects.onmicrosoft.com"])
    guests.compact_map { |g| g.email }.should eq(["amit@redant.com.au", "jon@example.com", "dev@acaprojects.onmicrosoft.com"])
    guests.compact_map { |g| g.preferred_name }.should eq(["Jon"])
    guests.compact_map { |g| g.phone }.should eq(["012334446"])
    guests.compact_map { |g| g.organisation }.should eq(["Google inc"])
    guests.compact_map { |g| g.notes }.should eq(["some notes"])
    guests.compact_map { |g| g.photo }.should eq(["http://example.com/first.jpg"])
    guests.compact_map { |g| g.searchable }.should eq(["amit  ", "john jon google inc", "dev@acaprojects.onmicrosoft.com  "])
    guests.compact_map { |g| g.ext_data }.should eq([{} of String => String?, {"fizz" => "buzz"}, {} of String => String?])

    # Update
    body = IO::Memory.new
    body << EventsHelper.update_event_input
    body.rewind
    response = IO::Memory.new
    context = context("PATCH", "/api/staff/v1/events/#{created_event["id"]}?system_id=sys-rJQQlR4Cn7", OFFICE365_HEADERS, body, response_io: response)
    context.route_params = {"id" => created_event["id"].to_s}
    Events.new(context).update
    updated_event = extract_json(response).as_h
    updated_event.should eq(EventsHelper.update_event_output)

    # Should have updated metadata record
    evt_meta = EventMetadata.query.find { event_id == updated_event["id"] }.not_nil!
    evt_meta.event_start.should eq(1598504460)
    evt_meta.event_end.should eq(1598508120)

    # Should still have 3 created attendees records
    # 2 guests + 1 host
    evt_meta.attendees.count.should eq(3)

    # Should have updated guests records
    guests = evt_meta.attendees.map { |a| a.guest }
    guests.map { |g| g.name }.should eq(["Amit", "dev@acaprojects.onmicrosoft.com", "Robert"])
    guests.compact_map { |g| g.email }.should eq(["amit@redant.com.au", "dev@acaprojects.onmicrosoft.com", "bob@example.com"])
    guests.compact_map { |g| g.preferred_name }.should eq(["bob"])
    guests.compact_map { |g| g.phone }.should eq(["012333336"])
    guests.compact_map { |g| g.organisation }.should eq(["Apple inc"])
    guests.compact_map { |g| g.notes }.should eq(["some updated notes"])
    guests.compact_map { |g| g.photo }.should eq(["http://example.com/bob.jpg"])
    guests.compact_map { |g| g.ext_data }.should eq([{"fuzz" => "bizz"}, {} of String => String?, {"buzz" => "fuzz"}])
  end

  it "#create should create event and #update should update for user calendar" do
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

    body = IO::Memory.new
    body << EventsHelper.create_event_input
    body.rewind
    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/events/", OFFICE365_HEADERS, body, response_io: response)
    Events.new(context).create
    created_event = extract_json(response).as_h

    # Update
    body = IO::Memory.new
    body << EventsHelper.update_event_input
    body.rewind
    response = IO::Memory.new
    context = context("PATCH", "/api/staff/v1/events/#{created_event["id"]}?calendar=dev@acaprojects.com", OFFICE365_HEADERS, body, response_io: response)
    context.route_params = {"id" => created_event["id"].to_s}
    Events.new(context).update

    extract_http_status(response).should eq("200")
  end
end

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
      "location"    => {"text" => ""},
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
    "location": {
        "text": "test"
    },
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
    "location": {
        "text": "test"
    },
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
    {"event_start" => 1598503500, "event_end" => 1598507160, "id" => "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=", "host" => "dev@acaprojects.onmicrosoft.com", "title" => "tentative event response status and default timezone trial updated", "body" => "yeehaw hiya", "attendees" => [{"name" => "Amit", "email" => "amit@redant.com.au", "response_status" => "accepted", "resource" => false, "checked_in" => false, "visit_expected" => true, "extension_data" => {} of String => String?}, {"name" => "John", "email" => "jon@example.com", "response_status" => "tentative", "resource" => false, "checked_in" => false, "visit_expected" => true, "extension_data" => {"fizz" => "buzz"}}, {"name" => "RM-AU-DP-L105-Swiss-Alps", "email" => "rmaudpswissalps@booking.demo.acaengine.com", "response_status" => "needsAction", "resource" => false, "extension_data" => {} of String => String?}, {"name" => "Developer", "email" => "dev@acaprojects.onmicrosoft.com", "response_status" => "accepted", "resource" => false, "checked_in" => false, "visit_expected" => true, "extension_data" => {} of String => String?}], "location" => {"text" => ""}, "private" => true, "all_day" => false, "timezone" => "Australia/Sydney", "recurring" => false, "attachments" => [] of String, "status" => "confirmed", "creator" => "dev@acaprojects.onmicrosoft.com", "calendar" => "room1@example.com", "system" => {"created_at" => 1562041110, "updated_at" => 1562041120, "id" => "sys-rJQQlR4Cn7", "name" => "Room 1", "zones" => ["zone-rGhCRp_aUD"], "modules" => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"], "email" => "room1@example.com", "capacity" => 10, "features" => [] of String, "bookable" => true, "installed_ui_devices" => 0, "version" => 5}, "extension_data" => {"foo" => "bar"}}
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
         "extension_data":    {
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
      "location"    => {"text" => ""},
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
end
