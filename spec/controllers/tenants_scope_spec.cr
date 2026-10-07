require "../spec_helper"

# PPT-526: tenant administration stays inside the caller's organisations
describe Tenants do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  after_each { Utils::Tenancy.enforce = false }

  it "scopes tenant administration to the caller's reach" do
    Utils::Tenancy.enforce = true
    toby = PlaceOS::Model::Authority.find_by_domain("toby.staff-api.dev").not_nil!

    management = PlaceOS::Model::Generator.partner(management: true).save!
    staff = PlaceOS::Model::Generator.organisation(partner: management, partner_staff: true).save!
    stranger_org = PlaceOS::Model::Generator.organisation.save!
    stranger = PlaceOS::Model::Generator.authority("stranger.staff-api.dev").tap(&.organisation_id = stranger_org.id).save!
    stranger_tenant = PlaceOS::Model::Generator.tenant(name: "Stranger", domain: "stranger.staff-api.dev")

    begin
      # a domain with no organisation reaches nothing
      toby.organisation_id = nil
      toby.save!
      JSON.parse(client.get(Tenants.base_route, headers: headers).body).as_a.should be_empty
      client.get("#{Tenants.base_route}/#{stranger_tenant.id}/limits", headers: headers).status_code.should eq 404

      # the management partner's staff reach every tenant
      toby.organisation_id = staff.id
      toby.save!
      domains = JSON.parse(client.get(Tenants.base_route, headers: headers).body).as_a.map(&.["domain"].as_s)
      domains.should contain("toby.staff-api.dev")
      domains.should contain("stranger.staff-api.dev")
      client.get("#{Tenants.base_route}/#{stranger_tenant.id}/limits", headers: headers).status_code.should eq 200

      # an ordinary organisation's admin sees only its own tenants
      own_org = PlaceOS::Model::Generator.organisation.save!
      toby.organisation_id = own_org.id
      toby.save!
      domains = JSON.parse(client.get(Tenants.base_route, headers: headers).body).as_a.map(&.["domain"].as_s)
      domains.should eq ["toby.staff-api.dev"]
      client.get("#{Tenants.base_route}/#{stranger_tenant.id}/limits", headers: headers).status_code.should eq 404
      client.patch("#{Tenants.base_route}/#{stranger_tenant.id}", headers: headers, body: {early_checkin: 60}.to_json).status_code.should eq 404

      body = {name: "Sneaky", domain: "stranger.staff-api.dev", platform: "office365", credentials: {tenant: "t", client_id: "c", client_secret: "s"}}.to_json
      client.post(Tenants.base_route, headers: headers, body: body).status_code.should eq 404

      # a grant into the stranger's organisation widens reach
      admin = PlaceOS::Model::User.find!(UserJWT.decode(Mock::Token.office).id)
      PlaceOS::Model::Generator.grant(admin, PlaceOS::Model::Grant::SCOPE_ORGANISATION, stranger_org.id.to_s).save!
      client.get("#{Tenants.base_route}/#{stranger_tenant.id}/limits", headers: headers).status_code.should eq 200
    ensure
      toby.organisation_id = nil
      toby.save!
      stranger_tenant.delete
      stranger.destroy
      PlaceOS::Model::Grant.clear
      PlaceOS::Model::Organisation.clear
      PlaceOS::Model::Partner.clear
    end
  end
end
