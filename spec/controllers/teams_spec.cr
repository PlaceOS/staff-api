require "../spec_helper"

describe Teams do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return the list of messages (without the replies) in a channel of a team" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/teams/my_teams/channels/my_channel/messages")
        .to_return(body: File.read("./spec/fixtures/teams/list.json"))

      body = JSON.parse(client.get("#{TEAMS_BASE}/my_teams/my_channel", headers: headers).body).as_h
      body["value"].as_a.size.should eq(3)
    end

    it "should return a single message or a message reply in a channel or a chat" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/teams/my_teams/channels/my_channel/messages/message_1")
        .to_return(body: File.read("./spec/fixtures/teams/index_filtered.json"))

      body = JSON.parse(client.get("#{TEAMS_BASE}/my_teams/my_channel/message_1", headers: headers).body).as_h
      body["messageType"].as_s.should eq("message")
    end
  end

  pending "should send a new chatMessage in the specified channel or a chat" do
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/teams/my_teams/channels/my_channel/messages")
      .to_return(status: 201)
    headers["Content-Type"] = "text/plain"
    body = client.post("#{TEAMS_BASE}/my_teams/my_channel", headers: headers, body: "Hello Teams")
    body.status_code.should eq(201)
  end
end

TEAMS_BASE = Teams.base_route
