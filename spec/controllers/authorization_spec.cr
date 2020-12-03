require "../spec_helper"

describe "Authorization" do
  it "should 403 if the domain in the header doesn't match the token" do
    headers = HTTP::Headers{
      "Host"          => "wrong.staff-api.dev",
      "Authorization" => "Bearer #{office_mock_token}",
    }

    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", headers, response_io: response))

    # Test the instance method of the controller
    expect_raises(Error::Unauthorized) do
      calendars.index
    end
  end

  it "should 403 if the token is invalid" do
    headers = HTTP::Headers{
      "Host"          => "toby.staff-api.dev",
      "Authorization" => "Bearer #{office_mock_token}e",
    }

    response = IO::Memory.new
    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", headers, response_io: response))

    # Test the instance method of the controller
    expect_raises(Error::Unauthorized) do
      calendars.index
    end
  end
end
