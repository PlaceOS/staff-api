require "../spec_helper"

describe "Authorization" do
  describe "raise Error::Unauthorized (status: 403)" do
    it "when the domain in the header doesn't match the token" do
      expect_raises(Error::Unauthorized) do
        Calendars.context("GET", Calendars.base_route, {
          "Host"          => "wrong.staff-api.dev",
          "Authorization" => "Bearer #{Mock::Token.office}",
        }, &.index)
      end
    end

    it "when the token is invalid" do
      expect_raises(Error::Unauthorized) do
        Calendars.context("GET", Calendars.base_route, {
          "Host"          => "toby.staff-api.dev",
          "Authorization" => "Bearer #{Mock::Token.office}e",
        }, &.index)
      end
    end
  end
end
