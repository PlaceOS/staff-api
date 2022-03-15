require "../spec_helper"
require "./helpers/spec_clean_up"

describe Tenants do
  describe "#index" do
    it "includes the booking limits" do
      body = Context(Tenants, JSON::Any).response("GET", TENANTS_BASE, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.first["booking_limits"]?.should be_truthy
    end
  end

  describe "#current_limits" do
    it "should return the limits for the current domain (any user)" do
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      body = Context(Tenants, JSON::Any).response("GET", TENANTS_BASE, headers: Mock::Headers.office365_guest, &.current_limits)[1].as_h
      body["desk"]?.should eq(2)
    end
  end

  describe "#show_limits" do
    it "should return the limits for the requested tenant (any user)" do
      tenant = get_tenant
      tenant.booking_limits = JSON.parse(%({"desk": 2}))
      tenant.save!

      body = Context(Tenants, JSON::Any).response("GET", TENANTS_BASE, route_params: {"id" => tenant.id.to_s}, headers: Mock::Headers.office365_guest, &.show_limits)[1].as_h
      body["desk"]?.should eq(2)
    end
  end
end

TENANTS_BASE = Tenants.base_route
