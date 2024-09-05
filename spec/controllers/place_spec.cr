require "../spec_helper"

describe Place do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of rooms" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/places/microsoft.graph.room")
        .to_return(body: File.read("./spec/fixtures/place/index.json"))

      rooms = Office365::PlaceList.from_json(client.get(PLACE_BASE, headers: headers).body)
      rooms.value.size.should eq(2)
      rooms.value.first.is_a?(Office365::Room).should be_true
    end
  end
end

PLACE_BASE = Place.base_route
