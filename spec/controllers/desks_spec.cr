require "../spec_helper"
require "./helpers/booking_helper"

DESKS_BASE = Desks.base_route

module DesksSpecHelper
  extend self

  BUILDING = "zone-desks-bld"
  LEVEL    = "zone-desks-l1"
  MAP_URL  = "https://toby.staff-api.dev/api/engine/v2/uploads/upload-desks/url"
  STORAGE  = "https://storage.example.com/maps/level-1.svg?signature=abc"

  # desk.1 is at (5, 5); desk.2 is 20 away, desk.4 50 and desk.3 100
  SVG = <<-SVG
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 100">
      <g id="desk ids">
        <rect id="desk.1" x="0" y="0" width="10" height="10"/>
        <rect id="desk.2" x="20" y="0" width="10" height="10"/>
        <g transform="translate(100 0)"><rect id="desk.3" x="0" y="0" width="10" height="10"/></g>
        <circle id="desk.4" cx="55" cy="5" r="5"/>
        <rect id="desk.5" x="200" y="0" width="10" height="10"/>
        <rect id="desk.6" x="300" y="0" width="10" height="10"/>
        <path id="locker.1" d="M 10 20 h 10 v 10 h -10 z"/>
      </g>
    </svg>
    SVG

  def zone(id : String, parent_id : String?, map_id : String? = nil) : PlaceOS::Model::Zone
    PlaceOS::Model::Zone.find?(id).try(&.delete)
    zone = PlaceOS::Model::Generator.zone
    zone.id = id
    zone.parent_id = parent_id
    zone.map_id = map_id
    zone.timezone = Time::Location.load("Europe/London")
    zone.save!
  end

  def asset(name : String, map_id : String?, type : PlaceOS::Model::AssetType, order : PlaceOS::Model::AssetPurchaseOrder, bookable = true, groups = [] of String) : PlaceOS::Model::Asset
    asset = PlaceOS::Model::Generator.asset(type, order)
    asset.name = name
    asset.map_id = map_id
    asset.zone_id = LEVEL
    asset.zones = ["zone-perm-org", BUILDING, LEVEL]
    asset.bookable = bookable
    asset.place_groups = groups
    asset.save!
  end

  # returns the assets by name
  def setup : Hash(String, PlaceOS::Model::Asset)
    Mock::Token.generate_auth_user(false, false)
    authority = PlaceOS::Model::Authority.find_by_domain("toby.staff-api.dev").not_nil!
    PlaceOS::Model::Asset.clear
    zone(BUILDING, "zone-perm-org")
    zone(LEVEL, BUILDING, "/api/engine/v2/uploads/upload-desks/url")

    order = PlaceOS::Model::Generator.asset_purchase_order(authority).save!
    desks = PlaceOS::Model::Generator.asset_type(PlaceOS::Model::Generator.asset_category(authority).save!).save!
    lockers = PlaceOS::Model::Generator.asset_type(PlaceOS::Model::Generator.asset_category(authority).save!).save!

    {
      "origin"   => asset("Desk 1", "desk.1", desks, order),
      "near"     => asset("Desk 2", "desk.2", desks, order),
      "far"      => asset("Desk 3", "desk.3", desks, order),
      "mid"      => asset("Desk 4", "desk.4", desks, order),
      "closed"   => asset("Desk 5", "desk.5", desks, order, bookable: false),
      "secret"   => asset("Desk 6", "desk.6", desks, order, groups: ["secret"]),
      "unmapped" => asset("Desk 99", "desk.99", desks, order),
      "locker"   => asset("Locker 1", "locker.1", lockers, order),
    }
  end

  # the map is a rest-api upload: it redirects to storage, which must not see the token
  def stub_map(svg : String = SVG) : Array(HTTP::Headers)
    seen = [] of HTTP::Headers
    WebMock.stub(:get, MAP_URL).to_return do |request|
      seen << request.headers.dup
      if request.headers["Authorization"]?.try(&.starts_with?("Bearer "))
        HTTP::Client::Response.new(307, headers: HTTP::Headers{"Location" => STORAGE})
      else
        HTTP::Client::Response.new(401)
      end
    end
    WebMock.stub(:get, STORAGE).to_return do |request|
      seen << request.headers.dup
      HTTP::Client::Response.new(200, body: svg, headers: HTTP::Headers{"Content-Type" => "image/svg+xml"})
    end
    seen
  end

  def period : String
    "period_start=#{Time.utc.to_unix}&period_end=#{2.hours.from_now.to_unix}"
  end
end

describe Desks do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  before_each do
    StaffApi::LevelMap.clear_cache
    Booking.clear
  end

  describe "#nearby" do
    it "ranks the available desks of the same kind by distance" do
      assets = DesksSpecHelper.setup
      DesksSpecHelper.stub_map

      response = client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["origin"].id}&#{DesksSpecHelper.period}", headers: headers)
      response.status_code.should eq 200
      body = JSON.parse(response.body)
      body["origin"]["id"].should eq assets["origin"].id
      body["level"]["id"].should eq DesksSpecHelper::LEVEL
      body["timezone"].should eq "Europe/London"
      # not the locker (another category), the unbookable desk, the group restricted desk
      # or the desk that isn't drawn on the map
      body["desks"].as_a.map(&.["id"].as_s).should eq [assets["near"].id, assets["mid"].id, assets["far"].id]
      body["desks"].as_a.map(&.["distance"].as_f).should eq [20.0, 50.0, 100.0]
    end

    it "sends the token to PlaceOS but not to the storage it redirects to" do
      assets = DesksSpecHelper.setup
      seen = DesksSpecHelper.stub_map

      client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["origin"].id}&#{DesksSpecHelper.period}", headers: headers).status_code.should eq 200
      seen.size.should eq 2
      seen[0]["Authorization"].should eq headers["Authorization"]
      seen[1]["Authorization"]?.should be_nil
    end

    it "caches the parsed map" do
      assets = DesksSpecHelper.setup
      seen = DesksSpecHelper.stub_map

      2.times do
        client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["origin"].id}&#{DesksSpecHelper.period}", headers: headers).status_code.should eq 200
      end
      seen.size.should eq 2
    end

    it "leaves out desks that are booked" do
      assets = DesksSpecHelper.setup
      DesksSpecHelper.stub_map
      BookingsHelper.create_booking(get_tenant.id.not_nil!, "someone@example.com", asset_id: assets["near"].id.not_nil!)

      response = client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["origin"].id}&#{DesksSpecHelper.period}", headers: headers)
      response.status_code.should eq 200
      JSON.parse(response.body)["desks"].as_a.map(&.["id"].as_s).should eq [assets["mid"].id, assets["far"].id]
    end

    it "includes group restricted desks for members of the group" do
      assets = DesksSpecHelper.setup
      DesksSpecHelper.stub_map
      member = Mock::Headers.office365_normal_user("desks-member@example.com", ["secret"])

      response = client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["origin"].id}&#{DesksSpecHelper.period}", headers: member)
      response.status_code.should eq 200
      JSON.parse(response.body)["desks"].as_a.map(&.["id"].as_s).should contain(assets["secret"].id)
    end

    it "searches near the desk a colleague has booked" do
      assets = DesksSpecHelper.setup
      DesksSpecHelper.stub_map
      booking = BookingsHelper.create_booking(get_tenant.id.not_nil!, "Colleague@example.com", asset_id: assets["far"].id.not_nil!)

      response = client.get("#{DESKS_BASE}/nearby?email=colleague@example.com", headers: headers)
      response.status_code.should eq 200
      body = JSON.parse(response.body)
      body["origin"]["id"].should eq assets["far"].id
      body["seated"].should eq "colleague@example.com"
      body["period_start"].as_i64.should be >= booking.booking_start
      body["period_end"].should eq booking.booking_end
      # desk.3 is at (105, 5): desk.4 is 50 away, desk.2 80 and desk.1 100
      body["desks"].as_a.map(&.["id"].as_s).should eq [assets["mid"].id, assets["near"].id, assets["origin"].id]
    end

    it "limits the results" do
      assets = DesksSpecHelper.setup
      DesksSpecHelper.stub_map

      response = client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["origin"].id}&limit=1&#{DesksSpecHelper.period}", headers: headers)
      JSON.parse(response.body)["desks"].as_a.map(&.["id"].as_s).should eq [assets["near"].id]
    end

    it "is not found when the colleague hasn't booked a desk" do
      DesksSpecHelper.setup
      client.get("#{DESKS_BASE}/nearby?email=nobody@example.com", headers: headers).status_code.should eq 404
    end

    it "is not found for another authority's desk" do
      DesksSpecHelper.setup
      other = PlaceOS::Model::Generator.authority("https://desks-other.example.com").save!
      type = PlaceOS::Model::Generator.asset_type(PlaceOS::Model::Generator.asset_category(other).save!).save!
      theirs = DesksSpecHelper.asset("Theirs", "desk.2", type, PlaceOS::Model::Generator.asset_purchase_order(other).save!)
      client.get("#{DESKS_BASE}/nearby?asset_id=#{theirs.id}", headers: headers).status_code.should eq 404
    end

    it "is not found when the desk isn't drawn on the map" do
      assets = DesksSpecHelper.setup
      DesksSpecHelper.stub_map
      client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["unmapped"].id}", headers: headers).status_code.should eq 404
    end

    it "requires a desk or colleague" do
      DesksSpecHelper.setup
      client.get("#{DESKS_BASE}/nearby", headers: headers).status_code.should eq 400
    end

    it "reports a map that can't be loaded" do
      assets = DesksSpecHelper.setup
      WebMock.stub(:get, DesksSpecHelper::MAP_URL).to_return(status: 404)
      response = client.get("#{DESKS_BASE}/nearby?asset_id=#{assets["origin"].id}", headers: headers)
      response.status_code.should eq 500
      response.body.should contain "level map"
    end
  end
end

describe "Bookings#book" do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  before_each { Booking.clear }

  it "books a desk for the signed in user, filed under the desk's level and building" do
    assets = DesksSpecHelper.setup
    starting = 1.hour.from_now.to_unix

    response = client.post("#{Bookings.base_route}/book?asset_id=#{assets["near"].id}&booking_start=#{starting}&booking_end=#{starting + 3600}&title=Near+the+team", headers: headers)
    response.status_code.should eq 201
    body = JSON.parse(response.body)
    body["booking_type"].should eq "desk"
    body["asset_id"].should eq assets["near"].id
    body["title"].should eq "Near the team"
    body["timezone"].should eq "Europe/London"
    zones = body["zones"].as_a.map(&.as_s)
    {DesksSpecHelper::LEVEL, DesksSpecHelper::BUILDING, "zone-perm-org"}.each { |zone| zones.should contain zone }

    booking = Booking.find(body["id"].as_i64)
    booking.user_email.to_s.should eq booking.booked_by_email.to_s
  end

  it "rejects a desk that's already booked" do
    assets = DesksSpecHelper.setup
    taken = BookingsHelper.create_booking(get_tenant.id.not_nil!, "someone@example.com", asset_id: assets["near"].id.not_nil!)

    response = client.post("#{Bookings.base_route}/book?asset_id=#{assets["near"].id}&booking_start=#{taken.booking_start}&booking_end=#{taken.booking_end}", headers: headers)
    response.status_code.should eq 409
  end

  it "books assets that aren't asset records using the zones provided" do
    starting = 1.hour.from_now.to_unix
    response = client.post("#{Bookings.base_route}/book?asset_id=desk-legacy-1&booking_start=#{starting}&booking_end=#{starting + 3600}&zones=zone-a,zone-b", headers: headers)
    response.status_code.should eq 201
    JSON.parse(response.body)["zones"].as_a.map(&.as_s).should eq ["zone-a", "zone-b"]
  end
end

describe StaffApi::LevelMap do
  it "finds the centre of shapes, groups and transformed elements" do
    map = StaffApi::LevelMap.new(DesksSpecHelper::SVG)
    map.centers["desk.1"].should eq StaffApi::LevelMap::Point.new(5.0, 5.0)
    map.centers["desk.3"].should eq StaffApi::LevelMap::Point.new(105.0, 5.0)
    map.centers["desk.4"].should eq StaffApi::LevelMap::Point.new(55.0, 5.0)
    map.centers["locker.1"].should eq StaffApi::LevelMap::Point.new(15.0, 25.0)
    map.distance("desk.1", "desk.2").should eq 20.0
    map.distance("desk.1", "missing").should be_nil
  end

  it "applies rotations and curves" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg">
        <rect id="rotated" x="0" y="0" width="10" height="20" transform="rotate(90)"/>
        <path id="curve" d="M 0 0 C 0 10 10 10 10 0"/>
      </svg>
      SVG
    map = StaffApi::LevelMap.new(svg)
    rotated = map.centers["rotated"]
    rotated.x.should be_close(-10.0, 1e-9)
    rotated.y.should be_close(5.0, 1e-9)
    # the curve peaks at y = 7.5, so its bounds are 0..10 by 0..7.5
    map.centers["curve"].x.should be_close(5.0, 1e-9)
    map.centers["curve"].y.should be_close(3.75, 1e-9)
  end
end
