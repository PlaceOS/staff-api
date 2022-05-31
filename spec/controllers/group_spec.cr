require "../spec_helper"

describe Groups do
  describe "#index" do
    it "should return a list of groups" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/groups?%24top=950")
        .to_return(body: File.read("./spec/fixtures/groups/index.json"))

      body = Context(Groups, JSON::Any).response("GET", "#{GROUPS_BASE}", headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(2)
    end

    it "should return a queryable list of groups" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/groups?%24filter=startswith%28displayName%2C+%272%27%29&%24top=950")
        .to_return(body: File.read("./spec/fixtures/groups/index_filtered.json"))

      body = Context(Groups, JSON::Any).response("GET", "#{GROUPS_BASE}", route_params: {"q" => "2"}, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)
    end
  end

  it "#show should return a single group" do
    group_id = "786aa06a-cc30-48fd-868f-99874442a840"

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/groups/#{group_id}")
      .to_return(body: File.read("./spec/fixtures/groups/show.json"))

    body = Context(Groups, PlaceCalendar::Group).response("GET", "#{GROUPS_BASE}/#{group_id}", route_params: {"id" => group_id}, headers: Mock::Headers.office365_guest, &.show)[1].as(PlaceCalendar::Group)
    body.id.should eq(group_id)
  end
end

GROUPS_BASE = Groups.base_route
