require "../spec_helper"

describe "Authorization" do
  it "raise Error::Unauthorized (status: 403) if the domain in the header doesn't match the token" do
    headers = HTTP::Headers{
      "Host"          => "wrong.staff-api.dev",
      "Authorization" => "Bearer #{office_mock_token}",
    }

    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", headers))

    # Test the instance method of the controller
    expect_raises(Error::Unauthorized) do
      calendars.index
    end
  end

  it "raise Error::Unauthorized (status: 403) if the token is invalid" do
    headers = HTTP::Headers{
      "Host"          => "toby.staff-api.dev",
      "Authorization" => "Bearer #{office_mock_token}e",
    }

    calendars = Calendars.new(context("GET", "/api/staff/v1/calendars", headers))

    # Test the instance method of the controller
    expect_raises(Error::Unauthorized) do
      calendars.index
    end
  end
end
