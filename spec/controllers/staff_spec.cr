require "../spec_helper"
require "./helpers/schedule_helper"

describe Staff do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of users" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24select=id%2CuserPrincipalName%2Csurname%2CpreferredLanguage%2CofficeLocation%2CmobilePhone%2Cmail%2CjobTitle%2CgivenName%2CdisplayName%2CbusinessPhones%2CaccountEnabled%2CmailNickname&%24filter=accountEnabled+eq+true")
        .to_return(body: File.read("./spec/fixtures/staff/index.json"))

      body = JSON.parse(client.get(STAFF_BASE, headers: headers).body).as_a
      body.size.should eq(2)
    end

    it "should return a queryable list of users" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24select=id%2CuserPrincipalName%2Csurname%2CpreferredLanguage%2CofficeLocation%2CmobilePhone%2Cmail%2CjobTitle%2CgivenName%2CdisplayName%2CbusinessPhones%2CaccountEnabled%2CmailNickname&%24filter=%28accountEnabled+eq+true%29+and+%28startswith%28displayName%2C%27john%27%29+or+startswith%28givenName%2C%27john%27%29+or+startswith%28surname%2C%27john%27%29+or+startswith%28mail%2C%27john%27%29%29")
        .to_return(body: File.read("./spec/fixtures/staff/index_filtered.json"))

      body = JSON.parse(client.get("#{STAFF_BASE}?q=john", headers: headers).body).as_a
      body.size.should eq(1)
    end

    it "should request and return additional user fields" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24select=id%2CuserPrincipalName%2Csurname%2CpreferredLanguage%2CofficeLocation%2CmobilePhone%2Cmail%2CjobTitle%2CgivenName%2CdisplayName%2CbusinessPhones%2CaccountEnabled%2CmailNickname%2CemployeeId%2Cdepartment&%24filter=accountEnabled+eq+true")
        .to_return(body: File.read("./spec/fixtures/staff/index_additional_fields.json"))

      body = JSON.parse(client.get("#{STAFF_BASE}?additional_fields=employeeId,%20department,employeeId", headers: headers).body).as_a
      body.size.should eq(2)
      body[0]["unmapped"]["employeeId"].should eq("E123")
      body[0]["unmapped"]["department"].should eq("Engineering")
    end
  end

  it "#show should return a single user" do
    user_id = "786aa06a-cc30-48fd-868f-99874442a840"

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/#{user_id}?%24select=id%2CuserPrincipalName%2Csurname%2CpreferredLanguage%2CofficeLocation%2CmobilePhone%2Cmail%2CjobTitle%2CgivenName%2CdisplayName%2CbusinessPhones%2CaccountEnabled%2CmailNickname")
      .to_return(body: File.read("./spec/fixtures/staff/show.json"))

    body = PlaceCalendar::User.from_json(client.get("#{STAFF_BASE}/#{user_id}", headers: headers).body)
    body.id.should eq(user_id)
  end

  describe "#free_busy" do
    starting = Time.utc(2026, 10, 14)
    ending = starting + 1.day
    period = "period_start=#{starting.to_unix}&period_end=#{ending.to_unix}"

    before_each do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    end

    it "returns the busy times of the person and me, from one request" do
      requested = ScheduleHelper.stub({
        "jane@example.com" => [{starting + 9.hours, starting + 10.hours}, {starting - 2.hours, starting - 1.hour}],
        ScheduleHelper::ME => [{starting - 1.hour, starting + 1.hour}],
      })

      response = client.get("#{STAFF_BASE}/Jane@Example.com/free_busy?#{period}", headers: headers)
      response.status_code.should eq 200
      body = JSON.parse(response.body).as_a
      body.map(&.["email"].as_s).should eq ["jane@example.com", ScheduleHelper::ME]
      # busy times outside the period are dropped, those overlapping it are clipped to it
      body[0]["busy"].should eq JSON.parse([{start: (starting + 9.hours).to_unix, end: (starting + 10.hours).to_unix}].to_json)
      body[1]["busy"].should eq JSON.parse([{start: starting.to_unix, end: (starting + 1.hour).to_unix}].to_json)
      requested.should eq [["jane@example.com", ScheduleHelper::ME]]
    end

    it "only checks me once when the person is me" do
      requested = ScheduleHelper.stub({} of String => Array(Tuple(Time, Time)))
      body = JSON.parse(client.get("#{STAFF_BASE}/#{ScheduleHelper::ME}/free_busy?#{period}", headers: headers).body).as_a
      body.map(&.["email"].as_s).should eq [ScheduleHelper::ME]
      requested.should eq [[ScheduleHelper::ME]]
    end

    it "rejects periods that are empty or longer than a week" do
      client.get("#{STAFF_BASE}/jane@example.com/free_busy?period_start=#{ending.to_unix}&period_end=#{starting.to_unix}", headers: headers).status_code.should eq 400
      client.get("#{STAFF_BASE}/jane@example.com/free_busy?period_start=#{starting.to_unix}&period_end=#{(starting + 8.days).to_unix}", headers: headers).status_code.should eq 400
    end

    it "is a card only tool" do
      _toolbox, tool = ActionController::MCPServer.description.tool?("staff_free_busy").not_nil!
      tool.visibility.should eq ["card"]
    end
  end
end

STAFF_BASE = Staff.base_route
