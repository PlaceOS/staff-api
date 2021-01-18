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

      ctx = context("GET", "/api/staff/v1/guests", OFFICE365_HEADERS)
      ctx.response.output = IO::Memory.new
      Guests.new(ctx).index

      results = JSON.parse(ctx.response.output.to_s)

      guest_names = results.as_a.map { |r| r["name"] }
      guest_emails = results.as_a.map { |r| r["email"] }
      guest_names.should eq(["Jon", "Steve"])
      guest_emails.should eq(["jon@example.com", "steve@example.com"])
    end

    it "query filtered should return a list of only matched guests" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
      GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

      ctx = context("GET", "/api/staff/v1/guests?q=steve", OFFICE365_HEADERS)
      ctx.response.output = IO::Memory.new
      Guests.new(ctx).index

      results = JSON.parse(ctx.response.output.to_s).as_a

      guest_names = results.map { |r| r["name"] }
      guest_emails = results.map { |r| r["email"] }
      guest_names.should eq(["Steve"])
      guest_emails.should eq(["steve@example.com"])
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
      route = "/api/staff/v1/guests?period_start=#{now}&period_end=#{later}&system_ids=sys-rJQQlR4Cn7,sys_id"
      ctx = context("GET", route, OFFICE365_HEADERS)
      ctx.response.output = IO::Memory.new
      Guests.new(ctx).index

      results = JSON.parse(ctx.response.output.to_s).as_a
      guest_names = results.map { |r| r["name"] }
      guest_emails = results.map { |r| r["email"] }
      guest_names.should eq(["Toby"])
      guest_emails.should eq(["toby@redant.com.au"])
      # Should have event info
      guest_events = results.map { |r| r["event"] }
      guest_events.should eq(GuestsHelper.guest_events_output)
    end
  end

  describe "#show" do
    it "should show a guests details" do
      WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
        .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")

      ctx = context("GET", "/api/staff/v1/guests/#{guest.email}/", OFFICE365_HEADERS)
      ctx.route_params = {"id" => guest.email.not_nil!}
      ctx.response.output = IO::Memory.new

      Guests.new(ctx).show

      results = JSON.parse(ctx.response.output.to_s)

      results.as_h["name"].should eq("Toby")
      results.as_h["email"].should eq("toby@redant.com.au")
      results.as_h["visit_expected"].should eq(false)
    end

    it "should show a guests details when visting today" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
      meta = EventMetadatasHelper.create_event(tenant.id, "128912891829182")
      guest.attendee_for(meta.id.not_nil!)

      ctx = context("GET", "/api/staff/v1/guests/#{guest.email}/", OFFICE365_HEADERS)
      ctx.route_params = {"id" => guest.email.not_nil!}
      ctx.response.output = IO::Memory.new

      Guests.new(ctx).show

      results = JSON.parse(ctx.response.output.to_s)

      results.as_h["name"].should eq("Toby")
      results.as_h["email"].should eq("toby@redant.com.au")
      results.as_h["visit_expected"].should eq(true)
    end
  end

  it "#destroy" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    toby = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
    GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

    ctx = context("DELETE", "/api/staff/v1/guests/#{toby.email}/", OFFICE365_HEADERS)
    ctx.route_params = {"id" => toby.email.not_nil!}
    Guests.new(ctx).destroy

    # Check only one is returned
    ctx = context("GET", "/api/staff/v1/guests", OFFICE365_HEADERS)
    ctx.response.output = IO::Memory.new
    Guests.new(ctx).index

    results = JSON.parse(ctx.response.output.to_s)

    # Only has steve, toby got deleted
    guest_names = results.as_a.map { |r| r["name"] }
    guest_emails = results.as_a.map { |r| r["email"] }
    guest_names.should eq(["Steve"])
    guest_emails.should eq(["steve@example.com"])
  end

  it "#create & #update" do
    body = IO::Memory.new
    body << %({"email":"toby@redant.com.au","banned":true,"extension_data":{"test":"data"}})
    body.rewind

    ctx = context("POST", "/api/staff/v1/guests/", OFFICE365_HEADERS, body)
    ctx.response.output = IO::Memory.new
    Guests.new(ctx).create
    create_results = JSON.parse(ctx.response.output.to_s)

    create_results.as_h["email"].should eq("toby@redant.com.au")
    create_results.as_h["banned"].should eq(true)
    create_results.as_h["dangerous"].should eq(false)
    create_results.as_h["extension_data"].should eq({"test" => "data"})

    body = IO::Memory.new
    body << %({"email":"toby@redant.com.au","dangerous":true,"extension_data":{"other":"info"}})
    body.rewind
    ctx = context("PATCH", "/api/staff/v1/guests/toby@redant.com.au", OFFICE365_HEADERS, body)
    ctx.route_params = {"id" => "toby@redant.com.au"}
    ctx.response.output = IO::Memory.new
    Guests.new(ctx).update
    update_results = JSON.parse(ctx.response.output.to_s)

    update_results.as_h["email"].should eq("toby@redant.com.au")
    update_results.as_h["banned"].should eq(true)
    update_results.as_h["dangerous"].should eq(true)
    update_results.as_h["extension_data"].should eq({"test" => "data", "other" => "info"})
    guest = Guest.query.find({email: update_results.as_h["email"]}).not_nil!
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

    ctx = context("GET", "/api/staff/v1/guests/#{guest.email}/meetings", OFFICE365_HEADERS)
    ctx.route_params = {"id" => guest.email.not_nil!}
    ctx.response.output = IO::Memory.new
    Guests.new(ctx).meetings

    results = JSON.parse(ctx.response.output.to_s)

    # Should get 1 event
    results.size.should eq(1)
  end
end

module GuestsHelper
  extend self

  def create_guest(tenant_id, name, email)
    guest = Guest.new
    guest.name = name
    guest.email = email
    guest.tenant_id = tenant_id
    guest.banned = false
    guest.dangerous = false
    guest.save!
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
