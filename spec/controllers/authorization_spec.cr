require "../spec_helper"

describe "Authorization" do
  describe "raise Error::Unauthorized (status: 403)" do
    it "when the domain in the header doesn't match the token" do
      expect_raises(Error::Unauthorized) do
        Calendars.context("GET", "/api/staff/v1/calendars", {
          "Host"          => "wrong.staff-api.dev",
          "Authorization" => "Bearer #{office_mock_token}",
        }, &.index)
      end
    end

    it "when the token is invalid" do
      expect_raises(Error::Unauthorized) do
        Calendars.context("GET", "/api/staff/v1/calendars", {
          "Host"          => "toby.staff-api.dev",
          "Authorization" => "Bearer #{office_mock_token}e",
        }, &.index)
      end
    end
  end
end
