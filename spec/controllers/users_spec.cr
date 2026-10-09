require "../spec_helper"

describe Users do
  client = AC::SpecHelper.client
  domain = "toby.staff-api.dev"
  current_path = "/api/staff/v1/users/current"

  describe "#current" do
    it "returns the signed in user's profile" do
      user = Mock::Token.generate_auth_user(false, false)
      response = client.get(current_path, headers: Mock::Headers.office365_guest)
      response.status_code.should eq 200

      body = JSON.parse(response.body)
      body["id"].should eq user.id
      body["email"].should eq user.email.to_s
      body["authority_id"].should eq user.authority_id
    end

    it "returns the user an API key acts as" do
      Mock::Token.generate_auth_user(false, false)
      authority = PlaceOS::Model::Authority.find_by_domain(domain).not_nil!
      key = PlaceOS::Model::Generator.api_key(authority)
      token = key.x_api_key.not_nil!
      key.save!

      response = client.get(current_path, headers: HTTP::Headers{"Host" => domain, "X-API-Key" => token})
      response.status_code.should eq 200
      JSON.parse(response.body)["id"].should eq key.user_id
    ensure
      key.try &.destroy
    end

    it "requires credentials" do
      response = client.get(current_path, headers: HTTP::Headers{"Host" => domain})
      response.status_code.should eq 401
    end

    it "rejects tokens issued for another domain" do
      headers = Mock::Headers.office365_guest
      headers["Host"] = "another.domain.dev"
      client.get(current_path, headers: headers).status_code.should eq 401
    end

    it "refuses guests, who don't have a user profile" do
      jwt = UserJWT.new(
        iss: "staff-api",
        iat: Time.local,
        exp: Time.local + 1.week,
        domain: domain,
        id: "guest@external.com",
        scope: [PlaceOS::Model::UserJWT::Scope::PUBLIC, PlaceOS::Model::UserJWT::Scope::GUEST],
        user: UserJWT::Metadata.new(
          name: "Guest Person",
          email: "guest@external.com",
          permissions: UserJWT::Permissions::User,
          roles: ["sys-guest"]
        )
      ).encode

      response = client.get(current_path, headers: HTTP::Headers{"Host" => domain, "Authorization" => "Bearer #{jwt}"})
      response.status_code.should eq 403
    end
  end
end
