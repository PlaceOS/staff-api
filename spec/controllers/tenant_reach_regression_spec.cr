require "../spec_helper"

module TenantReachSpec
  alias Model = PlaceOS::Model
  alias Permissions = Model::Permissions

  class Estate
    getter partner : Model::Partner
    getter organisation : Model::Organisation
    getter authority : Model::Authority
    getter user : Model::User
    getter own_tenant : Tenant
    @organisations = [] of Model::Organisation
    @authorities = [] of Model::Authority
    @grants = [] of Model::Grant

    def initialize(management = false, staff = false, admin = true)
      @partner = Model::Generator.partner(management: management).save!
      @organisation = organisation(@partner, staff)
      @authority = authority(@organisation)
      @user = Model::Generator.user(@authority, admin: admin).save!
      @own_tenant = Model::Generator.tenant(domain: @authority.domain)
    end

    def organisation(partner : Model::Partner? = nil, staff = false) : Model::Organisation
      org = Model::Generator.organisation(partner: partner, partner_staff: staff).save!
      @organisations << org
      org
    end

    def authority(org : Model::Organisation) : Model::Authority
      domain = "reach-#{UUID.random}.example.com"
      authority = Model::Generator.authority(domain).tap(&.organisation_id = org.id).save!
      @authorities << authority
      authority
    end

    def tenant(authority : Model::Authority) : Tenant
      Model::Generator.tenant(domain: authority.domain)
    end

    def grant(scope : String, id : String, permissions : Permissions, expires_at : Time? = nil) : Model::Grant
      grant = Model::Generator.grant(@user, scope, id, permissions, expires_at).save!
      @grants << grant
      grant
    end

    def headers(scope = [UserJWT::Scope::PUBLIC]) : HTTP::Headers
      generated = Model::Generator.jwt(@user, scope)
      token = UserJWT.new(
        iss: generated.iss, iat: generated.iat, exp: generated.exp,
        domain: @authority.domain, id: generated.id, user: generated.user, scope: generated.scope,
      )
      HTTP::Headers{"Host" => @authority.domain, "Authorization" => "Bearer #{token.encode}", "Content-Type" => "application/json"}
    end

    def close
      @grants.each(&.delete)
      Tenant.where(domain: @authorities.map(&.domain)).each(&.delete)
      @user.delete
      @authorities.reverse_each(&.delete)
      @organisations.reverse_each(&.delete)
      @partner.delete
    end
  end

  def self.with_estate(management = false, staff = false, admin = true, &)
    estate = Estate.new(management, staff, admin)
    Utils::Tenancy.enforce = true
    begin
      yield estate
    ensure
      Utils::Tenancy.enforce = false
      estate.close
    end
  end

  def self.body(domain : String, email_domain : String? = nil)
    {name: "Reach regression", domain: domain, email_domain: email_domain, platform: "office365",
     credentials: {tenant: "t", client_id: "c", client_secret: "s"}}.to_json
  end
end

describe "tenant administration reach regressions" do
  client = AC::SpecHelper.client

  it "keeps management-partner customer admins inside their own organisation" do
    TenantReachSpec.with_estate(management: true) do |estate|
      foreign = estate.tenant(estate.authority(estate.organisation))
      rows = JSON.parse(client.get(Tenants.base_route, headers: estate.headers).body).as_a
      rows.map(&.["domain"].as_s).should eq [estate.authority.domain]
      client.delete("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers).status_code.should eq 404
      Tenant.find?(foreign.id).should_not be_nil
    end
  end

  it "retains management staff cluster reach and ordinary partner staff reach" do
    TenantReachSpec.with_estate(management: true, staff: true) do |estate|
      foreign = estate.tenant(estate.authority(estate.organisation))
      client.get("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers).status_code.should eq 200
    end
    TenantReachSpec.with_estate(staff: true) do |estate|
      managed = estate.tenant(estate.authority(estate.organisation(estate.partner)))
      foreign = estate.tenant(estate.authority(estate.organisation))
      client.get("#{Tenants.base_route}/#{managed.id}/limits", headers: estate.headers).status_code.should eq 200
      client.get("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers).status_code.should eq 404
    end
  end

  it "keeps authority grants inside the exact domain, including list results" do
    TenantReachSpec.with_estate do |estate|
      other_org = estate.organisation
      allowed = estate.authority(other_org)
      sibling = estate.tenant(estate.authority(other_org))
      allowed_tenant = estate.tenant(allowed)
      estate.grant(PlaceOS::Model::Grant::SCOPE_AUTHORITY, allowed.id.to_s, TenantReachSpec::Permissions::Read)
      domains = JSON.parse(client.get(Tenants.base_route, headers: estate.headers).body).as_a.map(&.["domain"].as_s)
      domains.sort.should eq [estate.authority.domain, allowed.domain].sort
      client.get("#{Tenants.base_route}/#{allowed_tenant.id}/limits", headers: estate.headers).status_code.should eq 200
      client.get("#{Tenants.base_route}/#{sibling.id}/limits", headers: estate.headers).status_code.should eq 404
    end
  end

  it "does not turn a read grant into tenant update, create or delete access" do
    TenantReachSpec.with_estate do |estate|
      foreign_authority = estate.authority(estate.organisation)
      foreign = estate.tenant(foreign_authority)
      estate.grant(PlaceOS::Model::Grant::SCOPE_AUTHORITY, foreign_authority.id.to_s, TenantReachSpec::Permissions::Read)
      client.get("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers).status_code.should eq 200
      client.patch("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers, body: {early_checkin: 17}.to_json).status_code.should eq 404
      Tenant.find(foreign.id).early_checkin.should_not eq 17
      client.post(Tenants.base_route, headers: estate.headers, body: TenantReachSpec.body(foreign_authority.domain, "new.example.com")).status_code.should eq 404
      client.delete("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers).status_code.should eq 404
      Tenant.find?(foreign.id).should_not be_nil
    end
  end

  it "honours operation-only grants without widening the other verbs" do
    TenantReachSpec.with_estate do |estate|
      foreign_authority = estate.authority(estate.organisation)
      foreign = estate.tenant(foreign_authority)
      grant = estate.grant(PlaceOS::Model::Grant::SCOPE_AUTHORITY, foreign_authority.id.to_s, TenantReachSpec::Permissions::Update)
      client.patch("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers, body: {early_checkin: 19}.to_json).status_code.should eq 200
      Tenant.find(foreign.id).early_checkin.should eq 19
      client.post("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers, body: {desk: 7}.to_json).status_code.should eq 200
      client.post("#{Tenants.base_route}/#{foreign.id}/early_checkin", headers: estate.headers, body: "21").status_code.should eq 200
      client.get("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers).status_code.should eq 404
      client.delete("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers).status_code.should eq 404

      grant.permission_flags = TenantReachSpec::Permissions::Create
      grant.save!
      response = client.post(Tenants.base_route, headers: estate.headers, body: TenantReachSpec.body(foreign_authority.domain, "created.example.com"))
      response.status_code.should eq 201
      client.patch("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers, body: {early_checkin: 23}.to_json).status_code.should eq 404

      grant.permission_flags = TenantReachSpec::Permissions::Delete
      grant.save!
      client.delete("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers).status_code.should eq 202
      Tenant.find?(foreign.id).should be_nil
    end
  end

  it "intersects grants with JWT scope and the existing admin role" do
    TenantReachSpec.with_estate do |estate|
      foreign_authority = estate.authority(estate.organisation)
      foreign = estate.tenant(foreign_authority)
      estate.grant(PlaceOS::Model::Grant::SCOPE_AUTHORITY, foreign_authority.id.to_s, TenantReachSpec::Permissions::Manage)
      read_headers = estate.headers([UserJWT::Scope.new("public", :read)])
      client.patch("#{Tenants.base_route}/#{foreign.id}", headers: read_headers, body: {early_checkin: 23}.to_json).status_code.should eq 403
      Tenant.find(foreign.id).early_checkin.should_not eq 23
    end
    TenantReachSpec.with_estate(admin: false) do |estate|
      foreign_authority = estate.authority(estate.organisation)
      foreign = estate.tenant(foreign_authority)
      estate.grant(PlaceOS::Model::Grant::SCOPE_AUTHORITY, foreign_authority.id.to_s, TenantReachSpec::Permissions::Manage)
      client.patch("#{Tenants.base_route}/#{foreign.id}", headers: estate.headers, body: {early_checkin: 23}.to_json).status_code.should eq 403
    end
  end

  it "rejects a destination outside reach before changing a tenant's domain" do
    TenantReachSpec.with_estate do |estate|
      foreign_authority = estate.authority(estate.organisation)
      estate.tenant(foreign_authority)
      response = client.patch("#{Tenants.base_route}/#{estate.own_tenant.id}", headers: estate.headers,
        body: TenantReachSpec.body(foreign_authority.domain, "redirected.example.com"))
      response.status_code.should eq 404
      Tenant.find(estate.own_tenant.id).domain.should eq estate.authority.domain
      client.patch("#{Tenants.base_route}/#{estate.own_tenant.id}", headers: estate.headers, body: {early_checkin: 29}.to_json).status_code.should eq 200
      client.get("#{Tenants.base_route}/current_early_checkin", headers: estate.headers).body.should eq "29"
    end
  end

  it "ignores expired and revoked grants without changing host validation" do
    TenantReachSpec.with_estate do |estate|
      foreign_authority = estate.authority(estate.organisation)
      foreign = estate.tenant(foreign_authority)
      grant = estate.grant(PlaceOS::Model::Grant::SCOPE_AUTHORITY, foreign_authority.id.to_s, TenantReachSpec::Permissions::Manage, 1.minute.ago)
      client.get("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers).status_code.should eq 404
      grant.expires_at = nil
      grant.save!
      client.get("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers).status_code.should eq 200
      grant.delete
      client.get("#{Tenants.base_route}/#{foreign.id}/limits", headers: estate.headers).status_code.should eq 404
      headers = estate.headers
      headers["Host"] = foreign_authority.domain
      client.get("#{Tenants.base_route}/current_limits", headers: headers).status_code.should eq 401
    end
  end
end
