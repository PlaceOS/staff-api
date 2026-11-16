require "../../spec_helper"

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
      @organisation = new_organisation(@partner, staff)
      @authority = authority(@organisation)
      @user = Model::Generator.user(@authority, admin: admin).save!
      @own_tenant = Model::Generator.tenant(domain: @authority.domain)
    end

    def new_organisation(partner : Model::Partner? = nil, staff = false) : Model::Organisation
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
