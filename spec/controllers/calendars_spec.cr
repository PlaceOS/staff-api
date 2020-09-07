require "../spec_helper"

describe Calendars do
  it "should return a list of calendars" do
    # instantiate the controller
    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", OFFICE365_HEADERS, response_io: response))

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/index.json"))

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

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/index.json"))
    WebMock.stub(:post, "http://pwcme.dev.place.tech/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "http://pwcme.dev.place.tech/api/engine/v2/systems?limit=1000&offset=0&zone_id=zone-EzcsmWbvUG6")
      .to_return(body: File.read("./spec/fixtures/placeos/systems.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/getSchedule")
      .to_return(body: File.read("./spec/fixtures/events/o365/get_schedule.json"))

    calendars.availability

    results = extract_json(response)
    results.size.should be > 0
  end
end
