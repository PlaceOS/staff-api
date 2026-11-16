require "../spec_helper"

# Covers the code paths that replaced the PlaceOS crystal-client:
# API key auth, redis signals, zone system lookups, guest system access,
# delegated resource tokens and the office365 photo proxy.
module PlaceOSDirectSpec
  extend self

  DOMAIN      = "toby.staff-api.dev"
  O365_TOKEN  = "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token"
  BOOKINGS    = "/api/staff/v1/bookings"
  CALENDARS   = "/api/staff/v1/calendars"
  PEOPLE      = "/api/staff/v1/people"
  GRAPH_USERS = "https://graph.microsoft.com/v1.0/users"

  def unique(prefix : String) : String
    "#{prefix}-#{Random::Secure.hex(6)}"
  end

  def authority : PlaceOS::Model::Authority
    # ensures the authority exists with the tenant's domain
    Mock::Token.generate_auth_user(false, false)
    PlaceOS::Model::Authority.find_by_domain(DOMAIN).not_nil!
  end

  # Returns the persisted key and the X-API-Key header value
  def api_key : {PlaceOS::Model::ApiKey, String}
    key = PlaceOS::Model::Generator.api_key(authority)
    token = key.x_api_key.not_nil!
    key.save!
    {key, token}
  end

  def api_key_headers(token : String) : HTTP::Headers
    HTTP::Headers{"Host" => DOMAIN, "X-API-Key" => token}
  end

  def guest_headers(roles : Array(String)) : HTTP::Headers
    jwt = UserJWT.new(
      iss: "staff-api",
      iat: Time.local,
      exp: Time.local + 1.week,
      domain: DOMAIN,
      id: "guest@external.com",
      scope: [PlaceOS::Model::UserJWT::Scope::PUBLIC, PlaceOS::Model::UserJWT::Scope::GUEST],
      user: UserJWT::Metadata.new(
        name: "Guest Person",
        email: "guest@external.com",
        permissions: UserJWT::Permissions::User,
        roles: roles
      )
    ).encode
    HTTP::Headers{"Host" => DOMAIN, "Authorization" => "Bearer #{jwt}"}
  end

  # Stores resource tokens on the user, returning the previous values for restoring
  def set_tokens(user : PlaceOS::Model::User, access : String?, refresh : String? = nil, expires : Bool = false)
    previous = {user.access_token, user.refresh_token, user.expires_at, user.expires}
    user.access_token = access
    user.refresh_token = refresh
    user.expires_at = nil
    user.expires = expires
    user.save!
    previous
  end

  def restore_tokens(user_id : String, previous)
    user = PlaceOS::Model::User.find!(user_id)
    user.access_token, user.refresh_token, user.expires_at, user.expires = previous
    user.save!
  end

  def with_delegated_tenant(&)
    tenant = get_tenant
    tenant.delegated = true
    tenant.save!
    begin
      yield
    ensure
      tenant = get_tenant
      tenant.delegated = false
      tenant.save!
    end
  end

  def calendars_body : String
    File.read("./spec/fixtures/calendars/o365/show.json")
  end
end

describe "PlaceOS direct access" do
  client = AC::SpecHelper.client

  describe "X-API-Key authentication" do
    it "authenticates a valid key and acts as the key's user" do
      key, token = PlaceOSDirectSpec.api_key
      key_user = key.user.not_nil!
      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix

      response = client.post(PlaceOSDirectSpec::BOOKINGS, headers: PlaceOSDirectSpec.api_key_headers(token),
        body: %({"asset_id":"#{PlaceOSDirectSpec.unique("desk-apikey")}","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk"}))
      response.status_code.should eq 201

      body = JSON.parse(response.body)
      body["user_id"].as_s.should eq key_user.id
      body["booked_by_id"].as_s.should eq key_user.id
      body["user_email"].as_s.should eq key_user.email.to_s
    end

    it "rejects an unknown key with 401" do
      _key, token = PlaceOSDirectSpec.api_key
      id = token.split('.', 2).first
      bad_secret = "#{id}.#{Random::Secure.urlsafe_base64(32)}"

      response = client.get("#{PlaceOSDirectSpec::CALENDARS}/availability", headers: PlaceOSDirectSpec.api_key_headers(bad_secret))
      response.status_code.should eq 401

      response = client.get("#{PlaceOSDirectSpec::CALENDARS}/availability", headers: PlaceOSDirectSpec.api_key_headers("#{Random.new.hex(16)}.nope"))
      response.status_code.should eq 401
    end

    it "rejects an expired key with 401" do
      key, token = PlaceOSDirectSpec.api_key
      # model validation forbids saving a past expiry, so set it directly
      PgORM::Database.exec_sql("UPDATE api_key SET expires_at = $1 WHERE id = $2", 1.hour.ago, key.id.not_nil!)
      PlaceOS::Model::ApiKey.find!(key.id.not_nil!).expired?.should be_true

      response = client.get("#{PlaceOSDirectSpec::CALENDARS}/availability", headers: PlaceOSDirectSpec.api_key_headers(token))
      response.status_code.should eq 401
      response.body.should contain "API key has expired"
    end
  end

  describe "signals" do
    it "publishes booking changes globally and scoped to the authority" do
      authority_id = PlaceOSDirectSpec.authority.id.not_nil!
      asset_id = PlaceOSDirectSpec.unique("desk-signal-scope")
      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix

      created = JSON.parse(client.post(PlaceOSDirectSpec::BOOKINGS, headers: Mock::Headers.office365_guest,
        body: %({"asset_id":"#{asset_id}","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk"})).body)
      id = created["id"]

      global = SignalSpy.received("placeos/staff/booking/changed", &.["id"].==(id))
      scoped = SignalSpy.received("placeos/#{authority_id}/staff/booking/changed", &.["id"].==(id))
      global.size.should eq 1
      scoped.size.should eq 1

      {global.first.payload, scoped.first.payload}.each do |payload|
        payload["action"].should eq "create"
        payload["booking_type"].should eq "desk"
        payload["booking_start"].should eq starting
        payload["booking_end"].should eq ending
        payload["resource_id"].should eq asset_id
        payload["user_email"].should eq created["user_email"]
      end
      global.first.payload.should eq scoped.first.payload
    end
  end

  describe "Utils::PlaceOSHelpers.systems_in_zones" do
    it "returns systems in any of the zones" do
      zone_a = PlaceOSDirectSpec.unique("zone-a")
      zone_b = PlaceOSDirectSpec.unique("zone-b")
      other = PlaceOSDirectSpec.unique("zone-other")
      sys_a = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-a"), zones: [zone_a])
      sys_b = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-b"), zones: [other, zone_b])
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-c"), zones: [other])

      found = Utils::PlaceOSHelpers.systems_in_zones([zone_a, zone_b], [] of String, nil, nil)
      found.compact_map(&.id).sort!.should eq [sys_a.id, sys_b.id].compact.sort!
    end

    it "requires all of the features" do
      zone = PlaceOSDirectSpec.unique("zone-feat")
      both = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-both"), zones: [zone], features: ["vc", "whiteboard", "tv"])
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-vc"), zones: [zone], features: ["vc"])
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-none"), zones: [zone])

      found = Utils::PlaceOSHelpers.systems_in_zones([zone], ["vc", "whiteboard"], nil, nil)
      found.compact_map(&.id).should eq [both.id]

      Utils::PlaceOSHelpers.systems_in_zones([zone], [] of String, nil, nil).size.should eq 3
    end

    it "filters by minimum capacity" do
      zone = PlaceOSDirectSpec.unique("zone-cap")
      exact = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-cap8"), zones: [zone], capacity: 8)
      big = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-cap20"), zones: [zone], capacity: 20)
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-cap4"), zones: [zone], capacity: 4)

      found = Utils::PlaceOSHelpers.systems_in_zones([zone], [] of String, 8, nil)
      found.compact_map(&.id).sort!.should eq [exact.id, big.id].compact.sort!
    end

    it "filters by bookable" do
      zone = PlaceOSDirectSpec.unique("zone-bookable")
      bookable = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-bookable"), zones: [zone], bookable: true)
      unbookable = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-unbookable"), zones: [zone], bookable: false)

      Utils::PlaceOSHelpers.systems_in_zones([zone], [] of String, nil, true).compact_map(&.id).should eq [bookable.id]
      Utils::PlaceOSHelpers.systems_in_zones([zone], [] of String, nil, false).compact_map(&.id).should eq [unbookable.id]
      Utils::PlaceOSHelpers.systems_in_zones([zone], [] of String, nil, nil).size.should eq 2
    end

    it "combines the filters" do
      zone_a = PlaceOSDirectSpec.unique("zone-combo-a")
      zone_b = PlaceOSDirectSpec.unique("zone-combo-b")
      match = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-match"), zones: [zone_b], capacity: 10, features: ["vc"], bookable: true)
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-small"), zones: [zone_a], capacity: 2, features: ["vc"], bookable: true)
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-nofeat"), zones: [zone_a], capacity: 10, bookable: true)
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-closed"), zones: [zone_a], capacity: 10, features: ["vc"], bookable: false)
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-elsewhere"), zones: [PlaceOSDirectSpec.unique("zone-x")], capacity: 10, features: ["vc"], bookable: true)

      found = Utils::PlaceOSHelpers.systems_in_zones([zone_a, zone_b], ["vc"], 5, true)
      found.compact_map(&.id).should eq [match.id]
    end

    it "returns nothing for unrelated zones" do
      SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-unrelated"), zones: [PlaceOSDirectSpec.unique("zone-used")])
      Utils::PlaceOSHelpers.systems_in_zones([PlaceOSDirectSpec.unique("zone-empty")], [] of String, nil, nil).should be_empty
    end
  end

  describe "guest system access" do
    it "forbids a guest from a system not in their roles" do
      allowed = PlaceOSDirectSpec.unique("sys-guest-allowed")
      forbidden = SystemsHelper.system(id: PlaceOSDirectSpec.unique("sys-guest-forbidden"), email: "#{PlaceOSDirectSpec.unique("room")}@example.com")
      headers = PlaceOSDirectSpec.guest_headers([PlaceOSDirectSpec.unique("evt"), allowed])
      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix

      response = client.get("#{PlaceOSDirectSpec::CALENDARS}/availability?system_ids=#{forbidden.id}&period_start=#{starting}&period_end=#{ending}", headers: headers)
      response.status_code.should eq 403
    end

    it "lets a guest through to a system in their roles" do
      # the system doesn't exist, so passing the guard results in a 404 from the lookup
      allowed = PlaceOSDirectSpec.unique("sys-guest-missing")
      headers = PlaceOSDirectSpec.guest_headers([PlaceOSDirectSpec.unique("evt"), allowed])
      starting = 5.minutes.from_now.to_unix
      ending = 40.minutes.from_now.to_unix

      response = client.get("#{PlaceOSDirectSpec::CALENDARS}/availability?system_ids=#{allowed}&period_start=#{starting}&period_end=#{ending}", headers: headers)
      response.status_code.should eq 404
    end
  end

  describe "delegated tenants" do
    it "uses the user's stored resource token" do
      email = "delegated-token@example.com"
      headers = Mock::Headers.office365_normal_user(email)
      user = Mock::Token.generate_normal_auth_user(email)
      stored = "stored-#{Random::Secure.hex(8)}"
      previous = PlaceOSDirectSpec.set_tokens(user, stored)

      authorization = nil
      WebMock.stub(:get, "#{PlaceOSDirectSpec::GRAPH_USERS}/delegated-token%40example.com/calendars")
        .to_return do |request|
          authorization = request.headers["Authorization"]?
          HTTP::Client::Response.new(200, PlaceOSDirectSpec.calendars_body, HTTP::Headers{"Content-Type" => "application/json"})
        end

      begin
        PlaceOSDirectSpec.with_delegated_tenant do
          response = client.get(PlaceOSDirectSpec::CALENDARS, headers: headers)
          response.status_code.should eq 200
          authorization.should eq "Bearer #{stored}"
          JSON.parse(response.body).as_a.should_not be_empty
        end
      ensure
        PlaceOSDirectSpec.restore_tokens(user.id.not_nil!, previous)
      end
    end

    it "responds 511 when the user has no resource token" do
      email = "delegated-none@example.com"
      headers = Mock::Headers.office365_normal_user(email)
      user = Mock::Token.generate_normal_auth_user(email)
      previous = PlaceOSDirectSpec.set_tokens(user, nil, nil)

      begin
        PlaceOSDirectSpec.with_delegated_tenant do
          response = client.get(PlaceOSDirectSpec::CALENDARS, headers: headers)
          response.status_code.should eq 511
        end
      ensure
        PlaceOSDirectSpec.restore_tokens(user.id.not_nil!, previous)
      end
    end
  end

  describe "people photo" do
    it "streams the office365 photo using the user's resource token" do
      email = "photo-viewer@example.com"
      headers = Mock::Headers.office365_normal_user(email)
      user = Mock::Token.generate_normal_auth_user(email)
      stored = "photo-#{Random::Secure.hex(8)}"
      previous = PlaceOSDirectSpec.set_tokens(user, stored)
      photo = "fake-jpeg-bytes-#{Random::Secure.hex(4)}"
      target = "someone@example.com"

      WebMock.stub(:post, PlaceOSDirectSpec::O365_TOKEN)
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

      authorization = nil
      WebMock.stub(:get, "#{PlaceOSDirectSpec::GRAPH_USERS}/#{URI.encode_path_segment(target)}/photo/$value")
        .to_return do |request|
          authorization = request.headers["Authorization"]?
          HTTP::Client::Response.new(200, photo, HTTP::Headers{"Content-Type" => "image/jpeg"})
        end

      begin
        response = client.get("#{PlaceOSDirectSpec::PEOPLE}/#{target}/photo", headers: headers)
        response.status_code.should eq 200
        response.headers["Content-Type"]?.should eq "image/jpeg"
        response.body.should eq photo
        authorization.should eq "Bearer #{stored}"
      ensure
        PlaceOSDirectSpec.restore_tokens(user.id.not_nil!, previous)
      end
    end

    it "returns 511 when the user has no resource token" do
      email = "photo-viewer-no-token@example.com"
      headers = Mock::Headers.office365_normal_user(email)
      user = Mock::Token.generate_normal_auth_user(email)
      previous = PlaceOSDirectSpec.set_tokens(user, nil)

      WebMock.stub(:post, PlaceOSDirectSpec::O365_TOKEN)
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

      begin
        response = client.get("#{PlaceOSDirectSpec::PEOPLE}/someone@example.com/photo", headers: headers)
        response.status_code.should eq 511
      ensure
        PlaceOSDirectSpec.restore_tokens(user.id.not_nil!, previous)
      end
    end
  end
end
