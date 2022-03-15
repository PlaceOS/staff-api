require "../spec_helper"
require "./helpers/spec_clean_up"

describe Tenants do
  describe "#index" do
    it "includes the booking limits" do
      body = Context(Tenants, JSON::Any).response("GET", TENANTS_BASE, headers: Mock::Headers.office365_guest, &.index)[1].as_a
      body.first["booking_limits"]?.should be_truthy
    end
  end
end

TENANTS_BASE = Tenants.base_route
