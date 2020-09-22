require "../spec_helper"

describe Calendars do
  it "should return a list of calendars" do
    # instantiate the controller
    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", OFFICE365_HEADERS, response_io: response))

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

    calendars.index
  end

  it "should return list of available calendars" do
    now = Time.local.to_unix
    later = (Time.local + 1.hour).to_unix

    # instantiate the controller
    response = IO::Memory.new
    calendars = Calendars.new(
      context(
        "GET",
        "/api/staff/v1/calendars?calendars=dev@acaprojects.com&period_start=#{now}&period_end=#{later}&zone_ids=zone-EzcsmWbvUG6",
        OFFICE365_HEADERS,
        response_io: response
      )
    )

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=zone-EzcsmWbvUG6")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/getSchedule")
      .to_return(body: File.read("./spec/fixtures/events/o365/get_schedule.json"))

    calendars.availability

    results = extract_json(response).as_a
    results.should eq(CalendarsHelper.calendar_list_output)
  end
end

module CalendarsHelper
  extend self

  def calendar_list_output
    [{"id" => "dev@acaprojects.com"},
     {"id"     => "room1@example.com",
      "system" => {"created_at" => 1562041110,
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
                   "version" => 5}},
     {"id"     => "room2@example.com",
      "system" => {"created_at" => 1562041127,
                   "updated_at" => 1562041137,
                   "id" => "sys_id",
                   "name" => "Room 2",
                   "zones" => ["zone-rGhCRp_aUD"],
                   "modules" => ["mod-rJRJOM27Kb", "mod-rJRLE4_PQ7", "mod-rJRLwe72Mo"],
                   "email" => "room2@example.com",
                   "capacity" => 10,
                   "features" => [] of String,
                   "bookable" => true,
                   "installed_ui_devices" => 0,
                   "version" => 4}},
     {"id"     => "room3@example.com",
      "system" => {"created_at" => 1562041145,
                   "updated_at" => 1562041155,
                   "id" => "sys-rJQVPIR9Uf",
                   "name" => "Room 3",
                   "zones" => ["zone-rGhCRp_aUD"],
                   "modules" => ["mod-rJRNrLDPNz", "mod-rJRQ~JwE7U", "mod-rJRV1qokbH"],
                   "email" => "room3@example.com",
                   "capacity" => 4,
                   "features" => [] of String,
                   "bookable" => true,
                   "installed_ui_devices" => 0,
                   "version" => 4}},
     {"id"     => "room4@example.com",
      "system" => {"created_at" => 1562041145,
                   "updated_at" => 1562041155,
                   "id" => "sys-AAJQVPIR9Uf",
                   "name" => "Room 4",
                   "zones" => ["zone-rGhCRp_aUD"],
                   "modules" => ["mod-rJRNrLDPNz", "mod-rJRQ~JwE7U", "mod-rJRV1qokbH"],
                   "email" => "room4@example.com",
                   "capacity" => 20,
                   "features" => [] of String,
                   "bookable" => true,
                   "installed_ui_devices" => 0,
                   "version" => 4}}]
  end
end
