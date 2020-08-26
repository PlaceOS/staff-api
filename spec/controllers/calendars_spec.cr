require "../spec_helper"

describe Calendars do

  it "should return a list of calendars" do
    # instantiate the controller
    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", HEADERS, response_io: response))

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
        HEADERS, 
        response_io: response
      )
    )

    calendars.availability

    results = extract_json(response)
    results.size.should be > 0
  end

end
