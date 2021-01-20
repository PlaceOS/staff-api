require "../spec_helper"
require "./helpers/spec_clean_up"

describe Guests do
  systems_json = File.read("./spec/fixtures/placeos/systems.json")
  systems_resp = Array(JSON::Any).from_json(systems_json).map &.to_json

  describe "#index" do
    it "unfiltered should return a list of all guests" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
      GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}", headers: OFFICE365_HEADERS, &.index)[1].as_a

      # Guest names
      body.map(&.["name"]).should eq(["Jon", "Steve"])
      # Guest emails
      body.map(&.["email"]).should eq(["jon@example.com", "steve@example.com"])
    end

    it "query filtered should return a list of only matched guests" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
      GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}?q=steve", headers: OFFICE365_HEADERS, &.index)[1].as_a

      # Guest names
      body.map(&.["name"]).should eq(["Steve"])
      # Guest emails
      body.map(&.["email"]).should eq(["steve@example.com"])
    end

    pending "should return guests visiting today in a subset of rooms" do
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/$batch")
        .to_return(body: File.read("./spec/fixtures/events/o365/batch_index.json"))
      {"sys-rJQQlR4Cn7", "sys_id"}.each_with_index do |system_id, index|
        WebMock
          .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
          .to_return(body: systems_resp[index])
      end
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
      WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
        .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
      WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
        .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))

      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
      meta = EventMetadatasHelper.create_event(tenant.id, "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA=")
      guest.attendee_for(meta.id.not_nil!)

      now = Time.utc.to_unix
      later = 4.hours.from_now.to_unix
      route = "#{GUESTS_BASE}?period_start=#{now}&period_end=#{later}&system_ids=sys-rJQQlR4Cn7,sys_id"
      body = Context(Guests, JSON::Any).response("GET", route, headers: OFFICE365_HEADERS, &.index)[1].as_a

      # Guest names
      body.map(&.["name"]).should eq(["Toby"])
      # Guest emails
      body.map(&.["email"]).should eq(["toby@redant.com.au"])
      # Event info
      body.map(&.["event"]).should eq(GuestsHelper.guest_events_output)
    end
  end

  describe "#show" do
    it "should show a guests details" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/", route_params: {"id" => guest.email.not_nil!}, headers: OFFICE365_HEADERS, &.show)[1].as_h

      body["name"].should eq("Toby")
      body["email"].should eq("toby@redant.com.au")
      body["visit_expected"].should eq(false)
    end

    it "should show a guests details when visting today" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
      meta = EventMetadatasHelper.create_event(tenant.id, "128912891829182")
      guest.attendee_for(meta.id.not_nil!)

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/", route_params: {"id" => guest.email.not_nil!}, headers: OFFICE365_HEADERS, &.show)[1].as_h
      body["name"].should eq("Toby")
      body["email"].should eq("toby@redant.com.au")
      body["visit_expected"].should eq(true)
    end
  end

  it "#destroy" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    toby = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
    GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

    Guests.context("DELETE", "#{GUESTS_BASE}/#{toby.email}/", route_params: {"id" => toby.email.not_nil!}, headers: OFFICE365_HEADERS, &.destroy)

    # Check only one is returned
    body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}", headers: OFFICE365_HEADERS, &.index)[1].as_a

    # Only has steve, toby got deleted
    body.map(&.["name"]).should eq(["Steve"])
    body.map(&.["email"]).should eq(["steve@example.com"])
  end

  it "#create & #update" do
    req_body = %({"email":"toby@redant.com.au","banned":true,"extension_data":{"test":"data"}})
    created = Context(Guests, JSON::Any).response("POST", "#{GUESTS_BASE}/", body: req_body, headers: OFFICE365_HEADERS, &.create)[1].as_h

    created["email"].should eq("toby@redant.com.au")
    created["banned"].should eq(true)
    created["dangerous"].should eq(false)
    created["extension_data"].should eq({"test" => "data"})

    req_body = %({"email":"toby@redant.com.au","dangerous":true,"extension_data":{"other":"info"}})
    updated = Context(Guests, JSON::Any).response("PATCH", "#{GUESTS_BASE}/toby@redant.com.au", route_params: {"id" => "toby@redant.com.au"}, body: req_body, headers: OFFICE365_HEADERS, &.update)[1].as_h

    updated["email"].should eq("toby@redant.com.au")
    updated["banned"].should eq(true)
    updated["dangerous"].should eq(true)
    updated["extension_data"].should eq({"test" => "data", "other" => "info"})

    guest = Guest.query.find!({email: updated["email"]})
    guest.ext_data.not_nil!.as_h.should eq({"test" => "data", "other" => "info"})
  end

  it "#meetings should show meetings for guest" do
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/user@example.com/calendar/events/generic_event")
      .to_return(body: File.read("./spec/fixtures/events/o365/generic_event.json"))
    {"sys-rJQQlR4Cn7", "sys_id"}.each_with_index do |system_id, index|
      WebMock
        .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
        .to_return(body: systems_resp[index])
    end

    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
    meta = EventMetadatasHelper.create_event(tenant.id, "generic_event")
    guest.attendee_for(meta.id.not_nil!)

    body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/meetings", route_params: {"id" => guest.email.not_nil!}, headers: OFFICE365_HEADERS, &.meetings)[1].as_a
    # Should get 1 event
    body.size.should eq(1)
  end
end

GUESTS_BASE = Guests.base_route

module GuestsHelper
  extend self

  def create_guest(tenant_id, name, email)
    Guest.create({
      name:      name,
      email:     email,
      tenant_id: tenant_id,
      banned:    false,
      dangerous: false,
    })
  end

  def guest_events_output
    [{"event_start" => 1598832000,
      "event_end"   => 1598833800,
      "id"          => "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA=",
      "host"        => "dev@acaprojects.onmicrosoft.com",
      "title"       => "My new meeting",
      "body"        => "The quick brown fox jumps over the lazy dog",
      "attendees"   => [{"name" => "Toby Carvan",
                       "email" => "testing@redant.com.au",
                       "response_status" => "needsAction",
                       "resource" => false,
                       "extension_data" => {} of String => String?},
      {"name"            => "Amit Gaur",
       "email"           => "amit@redant.com.au",
       "response_status" => "needsAction",
       "resource"        => false,
       "extension_data"  => {} of String => String?}],
      "location"    => "",
      "private"     => true,
      "all_day"     => false,
      "timezone"    => "Australia/Sydney",
      "recurring"   => false,
      "attachments" => [] of String,
      "status"      => "confirmed",
      "creator"     => "dev@acaprojects.onmicrosoft.com"}]
  end
end
