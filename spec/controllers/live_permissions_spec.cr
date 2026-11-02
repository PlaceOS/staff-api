require "../spec_helper"
require "./helpers/survey_helper"

# sys_admin / support come from the user's current model, not the JWT claims, so changes
# apply to existing sessions. API keys deliberately keep their own stored permissions.
describe "live user permissions" do
  client = AC::SpecHelper.client
  domain = "toby.staff-api.dev"
  admin_path = Tenants.base_route # is_admin?

  new_user = ->(sys_admin : Bool, support : Bool) do
    # ensures the spec authority exists
    Mock::Token.office
    authority = PlaceOS::Model::Authority.find_by_domain(domain).not_nil!
    PlaceOS::Model::Generator.user(authority, support: support, admin: sys_admin).save!
  end

  bearer_headers = ->(user : PlaceOS::Model::User) do
    permissions = UserJWT::Permissions::User
    permissions |= UserJWT::Permissions::Admin if user.sys_admin
    permissions |= UserJWT::Permissions::Support if user.support
    token = UserJWT.new(
      iss: "staff-api",
      iat: Time.local,
      exp: Time.local + 1.week,
      domain: domain,
      id: user.id.as(String),
      scope: [UserJWT::Scope::PUBLIC],
      user: UserJWT::Metadata.new(
        name: user.name.as(String),
        email: user.email.to_s,
        permissions: permissions,
      ),
    )
    HTTP::Headers{
      "Host"          => domain,
      "Authorization" => "Bearer #{token.encode}",
    }
  end

  api_key_headers = ->(user : PlaceOS::Model::User, permissions : UserJWT::Permissions) do
    key = PlaceOS::Model::ApiKey.new(name: "live-permissions-#{user.id}")
    key.user = user
    key.permissions = permissions
    key.x_api_key
    key.save!
    HTTP::Headers{
      "Host"      => domain,
      "X-API-Key" => key.x_api_key.not_nil!,
    }
  end

  # survey questions may only be created by support (or admin)
  create_question = ->(headers : HTTP::Headers) do
    question = SurveyHelper.question_responders.first.to_json
    client.post(Surveys::Questions.base_route, headers: headers, body: question).status_code
  end

  it "revokes admin and support from a JWT once the user is demoted" do
    user = new_user.call(true, true)
    headers = bearer_headers.call(user)
    client.get(admin_path, headers: headers).status_code.should eq 200
    create_question.call(headers).should eq 201

    user.sys_admin = false
    user.support = false
    user.save!

    client.get(admin_path, headers: headers).status_code.should eq 403
    create_question.call(headers).should eq 403
  end

  it "downgrades an admin JWT to support when only admin is revoked" do
    user = new_user.call(true, true)
    headers = bearer_headers.call(user)

    user.sys_admin = false
    user.save!

    client.get(admin_path, headers: headers).status_code.should eq 403
    create_question.call(headers).should eq 201
  end

  it "elevates a JWT when the user is promoted" do
    user = new_user.call(false, false)
    headers = bearer_headers.call(user)

    client.get(admin_path, headers: headers).status_code.should eq 403
    create_question.call(headers).should eq 403

    user.sys_admin = true
    user.support = true
    user.save!

    client.get(admin_path, headers: headers).status_code.should eq 200
    create_question.call(headers).should eq 201
  end

  it "lets an API key grant more than its owner holds" do
    user = new_user.call(false, false)
    headers = api_key_headers.call(user, UserJWT::Permissions::AdminSupport)

    client.get(admin_path, headers: headers).status_code.should eq 200
    create_question.call(headers).should eq 201
  end

  it "rejects a JWT for a deleted user with 401" do
    user = new_user.call(true, true)
    headers = bearer_headers.call(user)
    user.destroy

    client.get(admin_path, headers: headers).status_code.should eq 401
  end

  it "rejects a JWT for a soft deleted user with 401" do
    user = new_user.call(true, true)
    headers = bearer_headers.call(user)
    user.deleted = true
    user.save!

    client.get(admin_path, headers: headers).status_code.should eq 401
  end

  it "rejects an API key for a soft deleted user with 401" do
    user = new_user.call(false, false)
    headers = api_key_headers.call(user, UserJWT::Permissions::AdminSupport)
    client.get(admin_path, headers: headers).status_code.should eq 200

    user.deleted = true
    user.save!

    client.get(admin_path, headers: headers).status_code.should eq 401
  end
end
