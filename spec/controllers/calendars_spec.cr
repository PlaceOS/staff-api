require "../spec_helper"

describe Calendars do

  it "should not work if the domain in the header doesn't match the token" do
    headers = HTTP::Headers{
      "Host"          => "wrong.staff-api.dev",
      "Authorization" => "Bearer #{mock_token}"
    }

    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", headers, response_io: response))

    # Test the instance method of the controller
    expect_raises(Error::Unauthorized) do
      calendars.index
    end
  end

  it "should not work if the token is malformed" do
    headers = HTTP::Headers{
      "Host"          => "toby.staff-api.dev",
      "Authorization" => "Bearer #{mock_token}e"
    }

    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", headers, response_io: response))

    # Test the instance method of the controller
    expect_raises(Error::Unauthorized) do
      calendars.index
    end
  end

  it "should return a list of calendars" do
    # instantiate the controller
    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", HEADERS, response_io: response))

    calendars.index
  end

end
