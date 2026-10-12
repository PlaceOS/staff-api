require "../spec_helper"
require "./helpers/event_helper"
require "./helpers/schedule_helper"

SPACES_BASE = Spaces.base_route

module SpacesSpecHelper
  extend self

  ORG      = "zone-perm-org"
  BUILDING = "zone-spaces-bld"
  LEVEL_1  = "zone-spaces-l1"
  LEVEL_2  = "zone-spaces-l2"
  OUTSIDE  = "zone-spaces-other"

  def zone(id : String, tags : Array(String), parent_id : String? = nil, name : String = id) : PlaceOS::Model::Zone
    PlaceOS::Model::Zone.find?(id).try(&.delete)
    zone = PlaceOS::Model::Generator.zone
    zone.id = id
    zone.name = name
    zone.tags = Set.new(tags)
    zone.parent_id = parent_id
    zone.save!
  end

  def setup
    Mock::Token.generate_auth_user(false, false) # creates the authority and its org zone
    zone(BUILDING, ["building"], ORG, "Spaces Building")
    level = zone(LEVEL_1, ["level"], BUILDING, "Spaces Level 1")
    level.timezone = Time::Location.load("Europe/London")
    level.save!
    zone(LEVEL_2, ["level"], BUILDING, "Spaces Level 2")
    zone(OUTSIDE, ["building"], nil, "Spaces Elsewhere")

    SystemsHelper.system("sys-spaces-1", "spaces-alpine@example.com", [ORG, BUILDING, LEVEL_1], "Spaces Alpine", 8, ["whiteboard", "vidconf"])
    SystemsHelper.system("sys-spaces-2", "spaces-bondi@example.com", [ORG, BUILDING, LEVEL_2], "Spaces Bondi", 4, ["display"])
    SystemsHelper.system("sys-spaces-3", nil, [ORG, BUILDING, LEVEL_2], "Spaces Cupboard", 20, ["projector"], bookable: false)
    SystemsHelper.system("sys-spaces-4", nil, [BUILDING, LEVEL_1], "Spaces Other Org", 20, ["secret"])
  end

  def ids(response : HTTP::Client::Response) : Array(String)
    response.status_code.should eq 200
    JSON.parse(response.body).as_a.map(&.["id"].as_s)
  end
end

describe Spaces do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  before_each do
    EventsHelper.stub_event_tokens
    SpacesSpecHelper.setup
  end

  describe "#index" do
    it "lists the bookable spaces in the organisation" do
      SpacesSpecHelper.ids(client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld", headers: headers)).should eq ["sys-spaces-1", "sys-spaces-2"]
    end

    it "filters by every zone" do
      SpacesSpecHelper.ids(client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld,zone-spaces-l1", headers: headers)).should eq ["sys-spaces-1"]
    end

    it "accepts lists as JSON arrays, as MCP clients send them" do
      zone_ids = URI.encode_www_form(%(["zone-spaces-bld","zone-spaces-l1"]))
      SpacesSpecHelper.ids(client.get("#{SPACES_BASE}?zone_ids=#{zone_ids}", headers: headers)).should eq ["sys-spaces-1"]
    end

    it "filters by every feature" do
      SpacesSpecHelper.ids(client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld&features=whiteboard,vidconf", headers: headers)).should eq ["sys-spaces-1"]
      SpacesSpecHelper.ids(client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld&features=whiteboard,display", headers: headers)).should be_empty
    end

    it "filters by minimum capacity" do
      SpacesSpecHelper.ids(client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld&capacity=6", headers: headers)).should eq ["sys-spaces-1"]
    end

    it "searches by name" do
      SpacesSpecHelper.ids(client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld&q=bond", headers: headers)).should eq ["sys-spaces-2"]
    end

    it "paginates" do
      response = client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld&limit=1", headers: headers)
      SpacesSpecHelper.ids(response).should eq ["sys-spaces-1"]
      response.headers["X-Total-Count"].should eq "2"
      response.headers["Link"].should contain "offset=1"
    end

    it "returns the space fields rather than the whole system" do
      response = client.get("#{SPACES_BASE}?zone_ids=zone-spaces-bld,zone-spaces-l1", headers: headers)
      space = JSON.parse(response.body).as_a.first.as_h
      space["name"].should eq "Spaces Alpine"
      space["email"].should eq "spaces-alpine@example.com"
      space["capacity"].should eq 8
      space["features"].should eq ["vidconf", "whiteboard"]
      space["zones"].should eq ["zone-perm-org", "zone-spaces-bld", "zone-spaces-l1"]
      space.has_key?("modules").should be_false
    end

    it "is not available to guests" do
      guest = Mock::Headers.office365_guest("guest-event", "sys-spaces-1")
      client.get(SPACES_BASE, headers: guest).status_code.should eq 403
    end
  end

  describe "#features" do
    it "lists the unique features of bookable spaces" do
      response = client.get("#{SPACES_BASE}/features?zone_ids=zone-spaces-bld", headers: headers)
      response.status_code.should eq 200
      JSON.parse(response.body).as_a.map(&.as_s).should eq ["display", "vidconf", "whiteboard"]
    end

    it "filters by every zone" do
      response = client.get("#{SPACES_BASE}/features?zone_ids=zone-spaces-bld,zone-spaces-l2", headers: headers)
      JSON.parse(response.body).as_a.map(&.as_s).should eq ["display"]
    end
  end

  describe "#free" do
    starting = Time.utc(2026, 10, 14, 9)
    ending = starting + 1.hour
    period = "period_start=#{starting.to_unix}&period_end=#{ending.to_unix}"

    it "lists the rooms in the only building that are free for the whole meeting" do
      requested = ScheduleHelper.stub({"spaces-alpine@example.com" => [{starting + 30.minutes, ending + 1.hour}]})
      body = JSON.parse(client.get("#{SPACES_BASE}/free?#{period}", headers: headers).body)
      body["buildings"].as_a.map(&.["id"].as_s).should eq [SpacesSpecHelper::BUILDING]
      body["zone_id"].should eq SpacesSpecHelper::BUILDING
      body["spaces"].as_a.map(&.["id"].as_s).should eq ["sys-spaces-2"]
      requested.map(&.sort).should eq [["spaces-alpine@example.com", "spaces-bondi@example.com"]]
    end

    it "lists the smallest free room first" do
      ScheduleHelper.stub({} of String => Array(Tuple(Time, Time)))
      body = JSON.parse(client.get("#{SPACES_BASE}/free?#{period}", headers: headers).body)
      body["spaces"].as_a.map(&.["id"].as_s).should eq ["sys-spaces-2", "sys-spaces-1"]
    end

    it "filters by level and capacity before checking calendars" do
      requested = ScheduleHelper.stub({} of String => Array(Tuple(Time, Time)))
      body = JSON.parse(client.get("#{SPACES_BASE}/free?#{period}&zone_id=#{SpacesSpecHelper::LEVEL_2}", headers: headers).body)
      body["spaces"].as_a.map(&.["id"].as_s).should eq ["sys-spaces-2"]
      body = JSON.parse(client.get("#{SPACES_BASE}/free?#{period}&capacity=6", headers: headers).body)
      body["spaces"].as_a.map(&.["id"].as_s).should eq ["sys-spaces-1"]
      requested.should eq [["spaces-bondi@example.com"], ["spaces-alpine@example.com"]]
    end

    it "waits for a building to be picked when there are several" do
      other = SpacesSpecHelper.zone("zone-spaces-bld2", ["building"], SpacesSpecHelper::ORG, "Another Building")
      begin
        requested = ScheduleHelper.stub({} of String => Array(Tuple(Time, Time)))
        body = JSON.parse(client.get("#{SPACES_BASE}/free?#{period}", headers: headers).body)
        body["buildings"].as_a.map(&.["id"].as_s).sort!.should eq ["zone-spaces-bld", "zone-spaces-bld2"]
        body["zone_id"].raw.should be_nil
        body["spaces"].as_a.should be_empty
        requested.should be_empty
      ensure
        other.delete
      end
    end

    it "rejects periods that are empty or longer than a day" do
      client.get("#{SPACES_BASE}/free?period_start=#{ending.to_unix}&period_end=#{starting.to_unix}", headers: headers).status_code.should eq 400
      client.get("#{SPACES_BASE}/free?period_start=#{starting.to_unix}&period_end=#{(starting + 25.hours).to_unix}", headers: headers).status_code.should eq 400
    end

    it "is a card only tool" do
      _toolbox, tool = ActionController::MCPServer.description.tool?("spaces_free").not_nil!
      tool.visibility.should eq ["card"]
    end
  end

  describe "#zones" do
    it "lists the organisation's zones by tag" do
      ids = SpacesSpecHelper.ids(client.get("#{SPACES_BASE}/zones?tags=building", headers: headers))
      ids.should contain "zone-spaces-bld"
      ids.should_not contain "zone-spaces-other"
    end

    it "lists the children of a zone" do
      response = client.get("#{SPACES_BASE}/zones?parent_id=zone-spaces-bld", headers: headers)
      SpacesSpecHelper.ids(response).should eq ["zone-spaces-l1", "zone-spaces-l2"]
      JSON.parse(response.body).as_a.first["tags"].should eq ["level"]
    end

    it "paginates and searches" do
      response = client.get("#{SPACES_BASE}/zones?parent_id=zone-spaces-bld&q=level&limit=1", headers: headers)
      SpacesSpecHelper.ids(response).should eq ["zone-spaces-l1"]
      response.headers["X-Total-Count"].should eq "2"
    end
  end

  describe "#show" do
    it "shows a space with today's meetings in its timezone" do
      WebMock.stub(:get, /spaces-alpine%40example\.com\/calendar\/calendarView/)
        .to_return(body: File.read("./spec/fixtures/events/o365/index.json"))

      response = client.get("#{SPACES_BASE}/sys-spaces-1", headers: headers)
      response.status_code.should eq 200
      body = JSON.parse(response.body)
      body["space"]["id"].should eq "sys-spaces-1"
      body["zones"].as_a.map(&.["id"].as_s).should eq ["zone-perm-org", "zone-spaces-bld", "zone-spaces-l1"]
      body["timezone"].should eq "Europe/London"

      today = Time.local(Time::Location.load("Europe/London")).at_beginning_of_day
      body["period_start"].should eq today.to_unix
      body["period_end"].should eq today.at_end_of_day.to_unix

      events = body["events"].as_a
      events.should_not be_empty
      events.first.as_h.keys.should contain "event_start"
      body.as_h.has_key?("events_error").should be_false
    end

    it "uses the period provided" do
      WebMock.stub(:get, /spaces-bondi%40example\.com\/calendar\/calendarView/)
        .to_return(body: %({"value": []}))

      starting = 2.days.from_now.to_unix
      ending = 3.days.from_now.to_unix
      body = JSON.parse(client.get("#{SPACES_BASE}/sys-spaces-2?period_start=#{starting}&period_end=#{ending}", headers: headers).body)
      body["period_start"].should eq starting
      body["period_end"].should eq ending
      body["events"].should eq [] of JSON::Any
    end

    it "still shows the space when its calendar can't be read" do
      WebMock.stub(:get, /spaces-bondi%40example\.com\/calendar\/calendarView/)
        .to_return(status: 500, body: %({"error": {"code": "ErrorInternalServerError", "message": "down"}}))

      response = client.get("#{SPACES_BASE}/sys-spaces-2", headers: headers)
      response.status_code.should eq 200
      body = JSON.parse(response.body)
      body["space"]["id"].should eq "sys-spaces-2"
      body.as_h.has_key?("events").should be_false
      body["events_error"].as_s.should contain "unable to read the space's calendar"
    end

    it "is 404 for systems that aren't bookable or are outside the organisation" do
      client.get("#{SPACES_BASE}/sys-spaces-3", headers: headers).status_code.should eq 404
      client.get("#{SPACES_BASE}/sys-spaces-4", headers: headers).status_code.should eq 404
      client.get("#{SPACES_BASE}/sys-missing", headers: headers).status_code.should eq 404
    end
  end

  describe "#image and #map" do
    upload = "https://toby.staff-api.dev/api/engine/v2/uploads/upload-photo/url"
    storage = "https://storage.example.com/photos/alpine.jpg?signature=abc"
    public_photo = "https://cdn.example.com/bondi.png"
    map_url = "https://toby.staff-api.dev/maps/level-1.svg"
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><rect id="room.alpine" x="10" y="10" width="20" height="10"/></svg>)

    before_each do
      StaffApi::LevelMap.clear_cache
      system = PlaceOS::Model::ControlSystem.find!("sys-spaces-1")
      system.images = ["/api/engine/v2/uploads/upload-photo/url", public_photo, "https://cdn.example.com/notes.txt"]
      system.map_id = "room.alpine"
      system.save!
      level = PlaceOS::Model::Zone.find!(SpacesSpecHelper::LEVEL_1)
      level.map_id = map_url
      level.save!
    end

    it "returns a photo uploaded to PlaceOS, only sending the token to PlaceOS" do
      seen = [] of HTTP::Headers
      WebMock.stub(:get, upload).to_return do |request|
        seen << request.headers.dup
        HTTP::Client::Response.new(307, headers: HTTP::Headers{"Location" => storage})
      end
      WebMock.stub(:get, storage).to_return do |request|
        seen << request.headers.dup
        HTTP::Client::Response.new(200, body: "JPEG-DATA", headers: HTTP::Headers{"Content-Type" => "image/jpeg"})
      end

      response = client.get("#{SPACES_BASE}/sys-spaces-1/images/0", headers: headers)
      response.status_code.should eq 200
      response.headers["Content-Type"].should start_with "image/jpeg"
      response.body.should eq "JPEG-DATA"
      seen[0]["Authorization"].should eq headers["Authorization"]
      seen[1]["Authorization"]?.should be_nil
    end

    it "returns a public photo" do
      WebMock.stub(:get, public_photo).to_return(body: "PNG-DATA", headers: HTTP::Headers{"Content-Type" => "image/png"})
      response = client.get("#{SPACES_BASE}/sys-spaces-1/images/1", headers: headers)
      response.status_code.should eq 200
      response.headers["Content-Type"].should start_with "image/png"
      response.body.should eq "PNG-DATA"
    end

    it "returns photos stored as downloads, by what's in them" do
      png = "\x89PNG\r\n\x1A\nPNG-DATA"
      WebMock.stub(:get, public_photo).to_return(body: png, headers: HTTP::Headers{
        "Content-Type"        => "application/octet-stream",
        "Content-Disposition" => %(attachment; filename="bondi.png"),
      })
      response = client.get("#{SPACES_BASE}/sys-spaces-1/images/1", headers: headers)
      response.status_code.should eq 200
      response.headers["Content-Type"].should start_with "image/png"
      response.body.should eq png
    end

    it "returns photos stored as downloads, by their file name" do
      WebMock.stub(:get, public_photo).to_return(body: "JPEG-DATA", headers: HTTP::Headers{
        "Content-Type"        => "binary/octet-stream",
        "Content-Disposition" => %(attachment; filename="bondi.JPG"),
      })
      response = client.get("#{SPACES_BASE}/sys-spaces-1/images/1", headers: headers)
      response.status_code.should eq 200
      response.headers["Content-Type"].should start_with "image/jpeg"
    end

    it "only returns images" do
      WebMock.stub(:get, "https://cdn.example.com/notes.txt").to_return(body: "hello", headers: HTTP::Headers{"Content-Type" => "text/plain"})
      client.get("#{SPACES_BASE}/sys-spaces-1/images/2", headers: headers).status_code.should eq 500

      WebMock.stub(:get, "https://cdn.example.com/notes.txt").to_return(body: "hello", headers: HTTP::Headers{
        "Content-Type"        => "application/octet-stream",
        "Content-Disposition" => %(attachment; filename="notes.txt"),
      })
      client.get("#{SPACES_BASE}/sys-spaces-1/images/2", headers: headers).status_code.should eq 500
    end

    it "is not found for a photo the space doesn't have" do
      client.get("#{SPACES_BASE}/sys-spaces-1/images/3", headers: headers).status_code.should eq 404
      client.get("#{SPACES_BASE}/sys-spaces-1/images/-1", headers: headers).status_code.should eq 404
    end

    it "returns the space's level map with its position" do
      building = PlaceOS::Model::Zone.find!(SpacesSpecHelper::BUILDING)
      building.map_id = "https://toby.staff-api.dev/maps/building.svg"
      building.save!
      WebMock.stub(:get, map_url).to_return(body: svg, headers: HTTP::Headers{"Content-Type" => "image/svg+xml"})

      response = client.get("#{SPACES_BASE}/sys-spaces-1/map", headers: headers)
      response.status_code.should eq 200
      response.headers["Content-Type"].should start_with "image/svg+xml"
      # the level's map, not the building's
      response.headers["X-Map-Level"].should eq SpacesSpecHelper::LEVEL_1
      response.headers["X-Map-Pin"].should eq "20.0,15.0"
      response.headers["X-Map-View-Box"].should eq "0.0 0.0 100.0 50.0"
    end

    it "is not found when the space isn't on a level with a map" do
      client.get("#{SPACES_BASE}/sys-spaces-2/map", headers: headers).status_code.should eq 404
    end
  end
end
