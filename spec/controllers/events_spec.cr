require "../spec_helper"

describe Events do
  it "index should return a list of events" do
    response = IO::Memory.new
    now = 1588407645
    later = 1588422097
    # instantiate the controller
    events = Events.new(context("GET", "/api/staff/v1/events?zone_ids=z1&period_start=#{now}&period_end=#{later}", OFFICE365_HEADERS, response_io: response))

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/index.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=z1")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/calendarView?startDateTime=2020-05-02T08:20:45-00:00&endDateTime=2020-05-02T12:21:37-00:00")
      .to_return(body: File.read("./spec/fixtures/events/o365/index.json"))

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

    results.as_a.should contain(EventsHelper.mock_event(id, event_start, event_end, system_id, room_email, host))
  end
end

module EventsHelper
  extend self

  def mock_event(id, event_start, event_end, system_id, room_email, host)
    {
      "event_start" => event_start,
      "event_end"   => event_end,
      "id"          => id,
      "host"        => host,
      "title"       => "My New Meeting, Delete me",
      "body"        => "The quick brown fox jumps over the lazy dog",
      "attendees"   => [{"name" => "Toby Carvan",
                       "email" => "testing@redant.com.au",
                       "response_status" => "needsAction",
                       "resource" => false},
      {"name"            => "Amit Gaur",
       "email"           => "amit@redant.com.au",
       "response_status" => "needsAction",
       "resource"        => false}],
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
      "extension_data" => {"foo" => 123},
    }
  end
end
