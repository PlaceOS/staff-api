require "../spec_helper"

describe Calendars do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  it "#index should return a list of calendars" do
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))

    # instantiate the controller
    client.get(CALENDARS_BASE, headers: headers).status_code.should eq(200)
  end

  describe "#availability" do
    it "should not return a calendar if it is busy at given time" do
      CalendarsHelper.stub_cal_endpoints
      time = Time.utc(2019, 3, 15, 10).to_unix
      time2 = Time.utc(2019, 3, 15, 11).to_unix
      route = "#{CALENDARS_BASE}?calendars=dev@acaprojects.com&period_start=#{time}&period_end=#{time2}&system_ids=sys-rJQQlR4Cn7,sys-rHQQlR4Cn7"

      body = JSON.parse(client.get(route, headers: headers).body)
      body.to_s.includes?("room1@example.com").should be_false
    end

    it "should not return a calendar if it is busy some of the given time" do
      CalendarsHelper.stub_cal_endpoints
      time = Time.utc(2020, 3, 15, 10).to_unix
      time2 = Time.utc(2020, 3, 15, 12).to_unix
      route = "#{CALENDARS_BASE}?calendars=dev@acaprojects.com&period_start=#{time}&period_end=#{time2}&system_ids=sys-rJQQlR4Cn7,sys-rHQQlR4Cn7"
      body = JSON.parse(client.get(route, headers: headers).body)
      body.to_s.includes?("room2@example.com").should be_false
    end

    it "should return list of available calendars" do
      CalendarsHelper.stub_cal_endpoints
      time = Time.utc(2021, 3, 15, 10).to_unix
      time2 = Time.utc(2021, 3, 15, 11).to_unix
      route = "#{CALENDARS_BASE}/availability?calendars=dev@acaprojects.com&period_start=#{time}&period_end=#{time2}&system_ids=sys-rJQQlR4Cn7,sys-rHQQlR4Cn7"
      body = JSON.parse(client.get(route, headers: headers).body)
      body.should eq(CalendarsHelper.calendar_list_output)
    end
  end

  it "#free_busy should return free busy data of calendars" do
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=zone-EzcsmWbvUG6")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/getSchedule")
      .to_return(body: File.read("./spec/fixtures/events/o365/get_schedule.json"))
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

    # looking at the mock data this should return all events but two that are outside the period
    tz = Time::Location.load("America/Los_Angeles")
    now = Time.parse("2019-03-15T12:00:00", "%Y-%m-%dT%H:%M:%S", tz).to_unix
    later = Time.parse("2019-03-15T13:30:00", "%Y-%m-%dT%H:%M:%S", tz).to_unix
    route = "#{CALENDARS_BASE}/free_busy?calendars=dev@acaprojects.com&period_start=#{now}&period_end=#{later}&zone_ids=zone-EzcsmWbvUG6"

    response = client.get(route, headers: headers)
    body = JSON.parse(response.body).as_a
    body.should eq(CalendarsHelper.free_busy_output)
  end

  it "#free_busy request with a duration < 30mins" do
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=zone-EzcsmWbvUG6")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/getSchedule")
      .to_return(body: File.read("./spec/fixtures/events/o365/get_schedule.json"))
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: "")

    # this should return only two events
    tz = Time::Location.load("America/Los_Angeles")
    now = Time.parse("2019-03-15T12:00:00", "%Y-%m-%dT%H:%M:%S", tz).to_unix
    later = Time.parse("2019-03-15T12:15:00", "%Y-%m-%dT%H:%M:%S", tz).to_unix

    route = "#{CALENDARS_BASE}/free_busy?calendars=dev@acaprojects.com&period_start=#{now}&period_end=#{later}&zone_ids=zone-EzcsmWbvUG6"
    body = JSON.parse(client.get(route, headers: headers).body).as_a
    body.should eq(CalendarsHelper.free_busy_output_15min)
  end

  it "#free_busy should not allow an interval of less than 5 minutes" do
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=zone-EzcsmWbvUG6")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/getSchedule")
      .to_return(body: File.read("./spec/fixtures/events/o365/get_schedule.json"))
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: "")

    tz = Time::Location.load("America/Los_Angeles")
    now = Time.parse("2019-03-15T12:00:00", "%Y-%m-%dT%H:%M:%S", tz).to_unix
    later = Time.parse("2019-03-15T12:04:00", "%Y-%m-%dT%H:%M:%S", tz).to_unix
    route = "#{CALENDARS_BASE}/free_busy?calendars=dev@acaprojects.com&period_start=#{now}&period_end=#{later}&zone_ids=zone-EzcsmWbvUG6"
    bad_request = client.get(route, headers: headers).status_code
    bad_request.should eq(400)
  end
end

CALENDARS_BASE = Calendars.base_route

module CalendarsHelper
  extend self

  def calendar_list_output
    [{"id" => "dev@acaprojects.com"},
     {"id" => "room1@example.com", "system" => {"created_at" => 1562041110, "updated_at" => 1562041120, "id" => "sys-rJQQlR4Cn7", "name" => "Room 1", "zones" => ["zone-rGhCRp_aUD"], "modules" => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"], "email" => "room1@example.com", "capacity" => 10, "features" => [] of String, "bookable" => true, "installed_ui_devices" => 0, "version" => 5}},
     {"id" => "room2@example.com", "system" => {"created_at" => 1562041110, "updated_at" => 1562041120, "id" => "sys-rHQQlR4Cn7", "name" => "Room 2", "zones" => ["zone-rGfCRp_aUD"], "modules" => ["mod-rJRCVFDVuB", "mod-rJRWE21pya", "mod-rJBGYsZExU"], "email" => "room2@example.com", "capacity" => 10, "features" => [] of String, "bookable" => true, "installed_ui_devices" => 0, "version" => 5}}]
  end

  def free_busy_output
    [{"id" => "jon@example.com", "availability" => [{"status" => "busy", "starts_at" => 1552676400, "ends_at" => 1552683600, "timezone" => "America/Los_Angeles"}]},
     {"id" => "room1@example.com", "system" => {"created_at" => 1562041110, "updated_at" => 1562041120, "id" => "sys-rJQQlR4Cn7", "name" => "Room 1", "zones" => ["zone-rGhCRp_aUD"], "modules" => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"], "email" => "room1@example.com", "capacity" => 10, "features" => [] of String, "bookable" => true, "installed_ui_devices" => 0, "version" => 5}, "availability" => [{"status" => "busy", "starts_at" => 1552676400, "ends_at" => 1552683600, "timezone" => "America/Los_Angeles"}, {"status" => "busy", "starts_at" => 1552676400, "ends_at" => 1552680000, "timezone" => "America/Los_Angeles"}, {"status" => "busy", "starts_at" => 1552680000, "ends_at" => 1552683600, "timezone" => "America/Los_Angeles"}]}]
  end

  def free_busy_output_15min
    [{"id" => "jon@example.com", "availability" => [{"status" => "busy", "starts_at" => 1552676400, "ends_at" => 1552683600, "timezone" => "America/Los_Angeles"}]},
     {"id" => "room1@example.com", "system" => {"created_at" => 1562041110, "updated_at" => 1562041120, "id" => "sys-rJQQlR4Cn7", "name" => "Room 1", "zones" => ["zone-rGhCRp_aUD"], "modules" => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"], "email" => "room1@example.com", "capacity" => 10, "features" => [] of String, "bookable" => true, "installed_ui_devices" => 0, "version" => 5}, "availability" => [{"status" => "busy", "starts_at" => 1552676400, "ends_at" => 1552683600, "timezone" => "America/Los_Angeles"}, {"status" => "busy", "starts_at" => 1552676400, "ends_at" => 1552680000, "timezone" => "America/Los_Angeles"}]}]
  end

  def stub_cal_endpoints
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "#{ENV["PLACE_URI"]}/api/engine/v2/systems?limit=1000&offset=0&zone_id=zone-EzcsmWbvUG6")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/getSchedule")
      .to_return(body: File.read("./spec/fixtures/events/o365/get_schedule_avail.json"))

    WebMock.stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/sys-rJQQlR4Cn7")
      .to_return(body: File.read("./spec/fixtures/placeos/systemJ.json"))

    WebMock.stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/sys-rHQQlR4Cn7")
      .to_return(body: File.read("./spec/fixtures/placeos/systemH.json"))

    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/")
      .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))
  end
end
