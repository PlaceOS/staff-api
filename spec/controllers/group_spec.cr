require "../spec_helper"

describe Groups do
  describe "#index" do
    it "should return a list of groups" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24filter=accountEnabled+eq+true")
        .to_return(body: File.read("./spec/fixtures/groups/index.json"))

      body = Context(Staff, JSON::Any).response("GET", "#{GROUPS_BASE}", headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(2)
    end

    it "should return a queryable list of users" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24filter=%28accountEnabled+eq+true%29+and+%28startswith%28displayName%2C%27john%27%29+or+startswith%28givenName%2C%27john%27%29+or+startswith%28surname%2C%27john%27%29+or+startswith%28mail%2C%27john%27%29%29")
        .to_return(body: File.read("./spec/fixtures/groups/index_filtered.json"))

      body = Context(Staff, JSON::Any).response("GET", "#{GROUPS_BASE}", route_params: {"q" => "2"}, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.size.should eq(1)
    end
  end

  it "#show should return a single user" do
    group_id = "786aa06a-cc30-48fd-868f-99874442a840"

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/#{group_id}")
      .to_return(body: File.read("./spec/fixtures/groups/show.json"))

    body = Context(Staff, PlaceCalendar::Group).response("GET", "#{GROUPS_BASE}/#{group_id}", route_params: {"id" => group_id}, headers: Mock::Headers.office365_guest, &.show)[1].as(PlaceCalendar::Group)
    body.id.should eq(group_id)
  end
end

GROUPS_BASE = Groups.base_route
