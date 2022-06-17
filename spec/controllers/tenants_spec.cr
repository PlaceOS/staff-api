require "../spec_helper"
require "./helpers/spec_clean_up"

describe Tenants do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "includes the booking limits" do
      body = JSON.parse(client.get(TENANTS_BASE, headers: headers).body).as_a
      body.first["booking_limits"]?.should be_truthy
    end
  end

  describe "#current_limits" do
    it "should return the limits for the current domain (any user)" do
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      resp = client.get("#{TENANTS_BASE}/current_limits", headers: headers)
      body = JSON.parse(resp.body)
      body["desk"]?.should eq(2)
    end
  end

  describe "#show_limits" do
    it "should return the limits for the requested tenant (any user)" do
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      resp = client.get("#{TENANTS_BASE}/current_limits", headers: headers)
      body = JSON.parse(resp.body)
      body["desk"]?.should eq(2)
    end
  end

  describe "#update_limits" do
    it "should set the limits (sys-admins only)" do
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      body = {booking_limits: {desk: 1}}.to_json
      response = client.patch("#{TENANTS_BASE}/#{tenant.id}", headers: headers, body: body)
      response.status_code.should eq(200)
      JSON.parse(response.body)["booking_limits"]["desk"]?.should eq(1)
    end
  end
end

TENANTS_BASE = Tenants.base_route
