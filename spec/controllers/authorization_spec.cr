require "../spec_helper"

describe "Authorization" do
  describe "raise Error::Unauthorized (status: 403)" do
    it "when the domain in the header doesn't match the token" do
      expect_raises(Error::Unauthorized) do
        Calendars.spec_instance(HTTP::Request.new("GET", Calendars.base_route, headers: HTTP::Headers{
          "Host"          => "wrong.staff-api.dev",
          "Authorization" => "Bearer #{Mock::Token.office}",
        })).index
      end
    end

    it "when the token is invalid" do
      expect_raises(Error::Unauthorized) do
        Calendars.spec_instance(HTTP::Request.new("GET", Calendars.base_route, headers: HTTP::Headers{
          "Host"          => "toby.staff-api.dev",
          "Authorization" => "Bearer #{Mock::Token.office}e",
        })).index
      end
    end
  end
end
