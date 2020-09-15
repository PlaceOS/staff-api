require "../spec_helper"

describe Staff do

  it "should return a list of users" do
    response = IO::Memory.new
    staff = Staff.new(context("GET", "/api/staff/v1/people", OFFICE365_HEADERS, response_io: response))

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24filter=accountEnabled+eq+true")
      .to_return(body: File.read("./spec/fixtures/staff/index.json"))

    staff.index

    results = extract_json(response)
    results.size.should eq(2)
  end

  it "should return a queryable list of users" do
    response = IO::Memory.new
    context = context("GET", "/api/staff/v1/people", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"q" => "john"}

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users?%24filter=%28accountEnabled+eq+true%29+and+%28startswith%28displayName%2C%27john%27%29+or+startswith%28givenName%2C%27john%27%29+or+startswith%28surname%2C%27john%27%29+or+startswith%28mail%2C%27john%27%29%29")
      .to_return(body: File.read("./spec/fixtures/staff/index_filtered.json"))

    Staff.new(context).index

    results = extract_json(response)
    results.size.should eq(1)
  end

  it "should return a single user" do
    user_id = "786aa06a-cc30-48fd-868f-99874442a840"

    response = IO::Memory.new
    context = context("GET", "/api/staff/v1/people/#{user_id}", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => user_id}

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/#{user_id}")
      .to_return(body: File.read("./spec/fixtures/staff/show.json"))

    Staff.new(context).show

    user = PlaceCalendar::User.from_json(extract_body(response))
    user.id.should eq(user_id)
  end

end
