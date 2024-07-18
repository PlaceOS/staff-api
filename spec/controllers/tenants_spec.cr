require "../spec_helper"

describe Tenants do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "includes the booking limits" do
      body = JSON.parse(client.get(TENANTS_BASE, headers: headers).body).as_a
      body.first["booking_limits"]?.should be_truthy
    end
  end

  describe "#update" do
    it "should set the booking_limits" do
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      body = {booking_limits: {desk: 1}}.to_json
      response = client.patch("#{TENANTS_BASE}/#{tenant.id}", headers: headers, body: body)
      response.status_code.should eq(200)
      JSON.parse(response.body)["booking_limits"]["desk"]?.should eq(1)
    end

    it "should set the early_checkin" do
      tenant = get_tenant
      tenant.early_checkin = 7200 # 2 hours
      tenant.save!

      body = {early_checkin: 3600}.to_json
      response = client.patch("#{TENANTS_BASE}/#{tenant.id}", headers: headers, body: body)
      response.status_code.should eq(200)
      JSON.parse(response.body)["early_checkin"]?.should eq(3600)
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

      body = {desk: 1}.to_json
      response = client.post("#{TENANTS_BASE}/#{tenant.id}/limits", headers: headers, body: body)
      response.status_code.should eq(200)
      JSON.parse(response.body)["desk"]?.should eq(1)
    end
  end

  describe "#current_early_checkin" do
    it "should return the early checkin limit for the current domain (any user)" do
      tenant = get_tenant
      tenant.early_checkin = 7200 # 2 hours
      tenant.save!

      resp = client.get("#{TENANTS_BASE}/current_early_checkin", headers: headers)
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body.should eq(7200)
    end
  end

  describe "#show_early_checkin" do
    it "should return the early checkin limit for the requested tenant (any user)" do
      tenant = get_tenant
      tenant.early_checkin = 7200 # 2 hours
      tenant.save!

      resp = client.get("#{TENANTS_BASE}/#{tenant.id}/early_checkin", headers: headers)
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body.should eq(7200)
    end
  end

  describe "#update_early_checkin" do
    it "should set the early checkin limit (sys-admins only)" do
      tenant = get_tenant
      tenant.early_checkin = 7200 # 2 hours
      tenant.save!

      request_body = 3600_i64.to_json
      resp = client.post("#{TENANTS_BASE}/#{tenant.id}/early_checkin", headers: headers, body: request_body)
      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body.should eq(3600)
    end
  end
end

TENANTS_BASE = Tenants.base_route
