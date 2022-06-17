require "../spec_helper"

describe Staff do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of users" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24filter=accountEnabled+eq+true")
        .to_return(body: File.read("./spec/fixtures/staff/index.json"))

      body = JSON.parse(client.get(STAFF_BASE, headers: headers).body).as_a
      body.size.should eq(2)
    end

    it "should return a queryable list of users" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24filter=%28accountEnabled+eq+true%29+and+%28startswith%28displayName%2C%27john%27%29+or+startswith%28givenName%2C%27john%27%29+or+startswith%28surname%2C%27john%27%29+or+startswith%28mail%2C%27john%27%29%29")
        .to_return(body: File.read("./spec/fixtures/staff/index_filtered.json"))

      body = JSON.parse(client.get("#{STAFF_BASE}?q=john", headers: headers).body).as_a
      body.size.should eq(1)
    end
  end

  it "#show should return a single user" do
    user_id = "786aa06a-cc30-48fd-868f-99874442a840"

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/#{user_id}")
      .to_return(body: File.read("./spec/fixtures/staff/show.json"))

    body = PlaceCalendar::User.from_json(client.get("#{STAFF_BASE}/#{user_id}", headers: headers).body)
    body.id.should eq(user_id)
  end
end

STAFF_BASE = Staff.base_route
