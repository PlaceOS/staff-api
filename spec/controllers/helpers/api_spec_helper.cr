require "mutex"

# Ported from rest-api's spec helpers (spec/spec_helpers), for the controllers ported from it.
# Named `ApiSpec` because staff-api specs run at the top level, where `Spec` is Crystal's spec
# module. Authenticates against the `localhost` authority, as rest-api does, which the models
# generator also uses by default (e.g. for asset categories).
module ApiSpec
  DOMAIN = "localhost"

  module Authentication
    CREATION_LOCK = Mutex.new(protection: :reentrant)

    def self.authenticated(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String) : Tuple(PlaceOS::Model::User, HTTP::Headers)
      authentication(sys_admin, support, scope, groups)
    end

    def self.user(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String) : PlaceOS::Model::User
      CREATION_LOCK.synchronize { authenticated(sys_admin, support, scope, groups).first }
    end

    def self.headers(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String) : HTTP::Headers
      CREATION_LOCK.synchronize { authenticated(sys_admin, support, scope, groups).last }
    end

    # an authenticated user, and headers with an Authorization bearer for the spec domain
    def self.authentication(sys_admin : Bool = true, support : Bool = true, scope = [PlaceOS::Model::UserJWT::Scope::PUBLIC], groups = [] of String)
      CREATION_LOCK.synchronize do
        user = generate_auth_user(sys_admin, support, scope, groups)
        jwt = PlaceOS::Model::Generator.jwt(user, scope)
        # staff-api requires the token's domain to match the request's Host
        token = PlaceOS::Model::UserJWT.new(
          iss: jwt.iss, iat: jwt.iat, exp: jwt.exp, domain: DOMAIN,
          id: jwt.id, user: jwt.user, scope: jwt.scope,
        )

        headers = HTTP::Headers{
          "Authorization" => "Bearer #{token.encode}",
          "Content-Type"  => "application/json",
          "Host"          => DOMAIN,
        }
        {user, headers}
      end
    end

    def self.generate_auth_user(sys_admin, support, scopes, groups = [] of String)
      CREATION_LOCK.synchronize do
        org_zone
        authority = PlaceOS::Model::Authority.find_by_domain(DOMAIN) || PlaceOS::Model::Generator.authority
        authority.domain = DOMAIN
        authority.config_will_change!
        authority.config["org_zone"] = JSON::Any.new("zone-perm-org")
        authority.save!

        scope_list = scopes.try &.join('-', &.to_s)
        group_list = groups.join('-')
        test_user_email = PlaceOS::Model::Email.new("test-#{"admin-" if sys_admin}#{"supp-" if support}scope-#{scope_list}-#{group_list}-rest-api@place.tech")

        PlaceOS::Model::User.where(email: test_user_email.to_s, authority_id: authority.id.as(String)).first? || PlaceOS::Model::Generator.user(authority, support: support, admin: sys_admin).tap do |user|
          user.email = test_user_email
          user.groups = groups
          user.save!
        end
      end
    end

    # the org zone, whose permissions metadata grants management admin and concierge manage
    def self.org_zone
      zone = PlaceOS::Model::Zone.find?("zone-perm-org")
      unless zone
        zone = PlaceOS::Model::Generator.zone
        zone.id = "zone-perm-org"
        zone.tags = Set.new ["org"]
        zone.save!
      end

      unless PlaceOS::Model::Metadata.where(parent_id: zone.id.as(String), name: "permissions").first?
        metadata = PlaceOS::Model::Generator.metadata("permissions", zone)
        metadata.details = JSON.parse({
          admin:  ["management"],
          manage: ["concierge"],
        }.to_json)
        metadata.save!
      end

      zone
    end
  end

  module Scopes
    extend self

    def show(base, id, scoped_headers)
      client.get(path: File.join(base, id.to_s), headers: scoped_headers)
    end

    def index(path, scoped_headers)
      client.get(path: path, headers: scoped_headers)
    end

    def create(path, body, scoped_headers)
      client.post(path: path, body: body, headers: scoped_headers)
    end

    def delete(base, id, scoped_headers)
      client.delete(path: File.join(base, id.to_s), headers: scoped_headers)
    end

    def update(path, body, scoped_headers)
      client.patch(path: path, body: body.to_json, headers: scoped_headers)
    end
  end

  # Check application responds with 404 when model not present
  def self.test_404(base, model_name, headers : HTTP::Headers, clz : Class = String)
    it "404s if #{model_name} isn't present in database", tags: "search" do
      id = (clz < Int) ? Random.rand(9999).to_s : "#{model_name}-#{Random.rand(9999).to_s.ljust(4, '0')}"
      path = File.join(base, id)
      result = client.get(path, headers: headers)

      result.status_code.should eq 404
    end
  end

  # Test search on name field (PG full-text search)
  macro test_base_index(klass, controller_klass)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "queries #{ {{ klass_name }} }", tags: "search" do
      _, headers = ApiSpec::Authentication.authentication
      doc = PlaceOS::Model::Generator.{{ klass_name.id }}
      name = random_name
      doc.name = name
      doc.save!
      doc.persisted?.should be_true

      params = HTTP::Params.encode({"q" => name})
      path = "#{{{controller_klass}}.base_route.rstrip('/')}?#{params}"

      result = client.get(path, headers: headers)
      result.status_code.should eq 200
      ids = Array(Hash(String, JSON::Any))
        .from_json(result.body)
        .map { |v| v["id"].as_i64? || v["id"].as_s? }
      ids.should contain(doc.id)
    end
  end

  macro test_create(klass, controller_klass, sys_admin = true, support = true, groups = nil)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "create" do
      groups = {{ groups }} || [] of String
      body = PlaceOS::Model::Generator.{{ klass_name.id }}.to_json
      result = client.post(
        {{ controller_klass }}.base_route,
        body: body,
        headers: ApiSpec::Authentication.headers(sys_admin: {{sys_admin}}, support: {{support}}, groups: groups)
      )

      result.status_code.should eq 201
      response_model = {{ klass.id }}.from_trusted_json(result.body)
      response_model.destroy
    end
  end

  macro test_show(klass, controller_klass, id_type = String)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "show" do
      model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
      model.persisted?.should be_true
      id = model.id.as({{ id_type.id }})
      result = client.get(
        path: File.join({{ controller_klass }}.base_route, id.to_s),
        headers: ApiSpec::Authentication.headers,
      )

      result.status_code.should eq 200
      response_model = {{ klass.id }}.from_trusted_json(result.body)
      response_model.id.should eq id

      model.destroy
    end
  end

  macro test_destroy(klass, controller_klass, id_type = String, sys_admin = true, support = true, groups = nil)
    {% klass_name = klass.stringify.split("::").last.underscore %}

    it "destroy" do
      groups = {{ groups }} || [] of String
      model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
      model.persisted?.should be_true
      id = model.id.as({{ id_type.id }})
      result = client.delete(
        path: File.join({{ controller_klass }}.base_route, id.to_s),
        headers: ApiSpec::Authentication.headers(sys_admin: {{sys_admin}}, support: {{support}}, groups: groups)
      )

      result.success?.should eq true
      {{ klass.id }}.find?(id).should be_nil
    end
  end

  macro test_crd(klass, controller_klass, id_type = String, sys_admin = true, support = true, groups = nil)
    ApiSpec.test_create({{ klass }}, {{ controller_klass }}, {{sys_admin}}, {{support}}, {{groups}})
    ApiSpec.test_show({{ klass }}, {{ controller_klass }}, {{ id_type }})
    ApiSpec.test_destroy({{ klass }}, {{ controller_klass }}, {{ id_type }}, {{sys_admin}}, {{support}}, {{groups}})
  end

  macro test_controller_scope(klass, id_type = String)
    {% base = klass.resolve.constant(:NAMESPACE).first %}

    {% if klass.stringify == "AssetCategories" %}
      {% model_name = "AssetCategory" %}
      {% model_gen = "asset_category" %}
    {% else %}
      {% model_name = klass.stringify.gsub(/[s]$/, " ").strip %}
      {% model_gen = model_name.underscore %}
    {% end %}

    {% scope_name = klass.stringify.underscore %}

    context "read" do
      it "allows access to show" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = ApiSpec::Scopes.show({{ base }}, id, scoped_headers)
        result.status_code.should eq 200
        response_model = PlaceOS::Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.id.should eq id
        model.destroy
      end

      it "allows access to index" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        result = ApiSpec::Scopes.index({{ base }}, scoped_headers)
        result.success?.should be_true
      end

      it "should not allow access to create" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = ApiSpec::Scopes.create({{ base }}, body, scoped_headers)
        result.status_code.should eq 403
      end

      it "should not allow access to delete" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :read)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = ApiSpec::Scopes.delete({{ base }}, id, scoped_headers)
        result.status_code.should eq 403
        PlaceOS::Model::{{ model_name.id }}.find?(id).should_not be_nil
      end
    end

    context "write" do
      it "should not allow access to show" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = ApiSpec::Scopes.show({{ base }}, id, scoped_headers)
        result.status_code.should eq 403
        model.destroy
      end

      it "should not allow access to index" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        result = ApiSpec::Scopes.index({{ base }}, scoped_headers)
        result.status_code.should eq 403
      end

      it "should allow access to create" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])

        body = PlaceOS::Model::Generator.{{ model_gen.id }}.to_json
        result = ApiSpec::Scopes.create({{ base }}, body, scoped_headers)
        result.success?.should be_true

        response_model = PlaceOS::Model::{{ model_name.id }}.from_trusted_json(result.body)
        response_model.destroy
      end

      it "should allow access to delete" do
        _, scoped_headers = ApiSpec::Authentication.authentication(scope: [PlaceOS::Model::UserJWT::Scope.new({{scope_name}}, :write)])
        model = PlaceOS::Model::Generator.{{ model_gen.id }}.save!
        model.persisted?.should be_true
        id = model.id.as({{ id_type.id }})
        result = ApiSpec::Scopes.delete({{ base }}, id, scoped_headers)
        result.success?.should be_true
        PlaceOS::Model::{{ model_name.id }}.find?(id).should be_nil
      end
    end
  end
end

# a shared spec client, as rest-api's specs use
API_SPEC_CLIENT = AC::SpecHelper.client

def client
  API_SPEC_CLIENT
end

def random_name
  UUID.random.to_s.split('-').first
end

# Clears just the group-system tables. Groups allow one root per authority and grants apply to
# the shared spec users, so specs that create groups clear them before each example.
def clear_group_tables
  [
    PlaceOS::Model::GroupHistory,
    PlaceOS::Model::GroupInvitation,
    PlaceOS::Model::GroupZone,
    PlaceOS::Model::GroupUser,
    PlaceOS::Model::GroupPlaylistItem,
    PlaceOS::Model::GroupPlaylist,
    PlaceOS::Model::GroupSignageTemplate,
    PlaceOS::Model::Group,
    PlaceOS::Model::DoorkeeperApplication,
  ].each(&.clear)
end
