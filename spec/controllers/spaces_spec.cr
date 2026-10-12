require "../spec_helper"
require "./helpers/event_helper"

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
end
