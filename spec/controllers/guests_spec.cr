require "../spec_helper"
require "./helpers/spec_clean_up"
require "../../src/constants"

describe Guests do
  systems_json = File.read("./spec/fixtures/placeos/systems.json")
  systems_resp = Array(JSON::Any).from_json(systems_json).map &.to_json

  describe "#index" do
    it "unfiltered should return a list of all guests" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
      GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}", headers: Mock::Headers.office365_guest, &.index)[1].as_a

      # Guest names
      body.map(&.["name"]).should eq(["Jon", "Steve"])
      # Guest emails
      body.map(&.["email"]).should eq(["jon@example.com", "steve@example.com"])
    end

    it "query filtered should return a list of only matched guests" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
      GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}?q=steve", headers: Mock::Headers.office365_guest, &.index)[1].as_a

      # Guest names
      body.map(&.["name"]).should eq(["Steve"])
      # Guest emails
      body.map(&.["email"]).should eq(["steve@example.com"])
    end

    pending "should return guests visiting today in a subset of rooms and bookings" do
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

      guest2 = GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
      booking = BookingsHelper.create_booking(tenant.id)
      Attendee.create!({booking_id:     booking.id,
                        guest_id:       guest2.id,
                        tenant_id:      guest2.tenant_id,
                        checked_in:     false,
                        visit_expected: true,
      })

      now = Time.utc.to_unix
      later = 4.hours.from_now.to_unix
      route = "#{GUESTS_BASE}?period_start=#{now}&period_end=#{later}&system_ids=sys-rJQQlR4Cn7,sys_id"
      body = Context(Guests, JSON::Any).response("GET", route, headers: Mock::Headers.office365_guest, &.index)[1].as_a

      # Guest names
      body.map(&.["name"]).should eq(["Toby", "Jon"])
      # Guest emails
      body.map(&.["email"]).should eq(["toby@redant.com.au", "jon@example.com"])
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

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/", route_params: {"id" => guest.email.not_nil!}, headers: Mock::Headers.office365_guest, &.show)[1].as_h

      body["name"].should eq("Toby")
      body["email"].should eq("toby@redant.com.au")
      body["visit_expected"].should eq(false)
    end

    it "should show a guests details when visting today" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
      meta = EventMetadatasHelper.create_event(tenant.id, "128912891829182")
      guest.attendee_for(meta.id.not_nil!)

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/", route_params: {"id" => guest.email.not_nil!}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
      body["name"].should eq("Toby")
      body["email"].should eq("toby@redant.com.au")
      body["visit_expected"].should eq(true)
    end

    it "should show a guest with booking details when visting today for a booking" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
      booking = BookingsHelper.create_booking(tenant.id)
      Attendee.create!({booking_id:     booking.id,
                        guest_id:       guest.id,
                        tenant_id:      guest.tenant_id,
                        checked_in:     false,
                        visit_expected: true,
      })

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/", route_params: {"id" => guest.email.not_nil!}, headers: Mock::Headers.office365_guest, &.show)[1].as_h
      body["name"].should eq("Toby")
      body["email"].should eq("toby@redant.com.au")
      body["visit_expected"].should eq(true)
      body["booking"]["id"].should eq(booking.id)
    end
  end

  describe "#bookings" do
    it "should show bookings for a guest when visting" do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
      booking = BookingsHelper.create_booking(tenant.id)
      Attendee.create!({booking_id:     booking.id,
                        guest_id:       guest.id,
                        tenant_id:      guest.tenant_id,
                        checked_in:     false,
                        visit_expected: true,
      })

      body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/bookings", route_params: {"id" => guest.email.not_nil!}, headers: Mock::Headers.office365_guest, &.bookings)[1].as_a
      body.map(&.["id"]).should eq([booking.id])
    end
  end

  it "#destroy" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    dave = GuestsHelper.create_guest(tenant.id, "Dave", "dave@redant.com.au")
    GuestsHelper.create_guest(tenant.id, "Elvis", "elvis@example.com")

    Guests.context("DELETE", "#{GUESTS_BASE}/#{dave.email}/", route_params: {"id" => dave.email.not_nil!}, headers: Mock::Headers.office365_guest, &.destroy)

    # Check only one is returned
    body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}", headers: Mock::Headers.office365_guest, &.index)[1].as_a

    # Only has steve, toby got deleted
    body.map(&.["name"]).should eq(["Elvis"])
    body.map(&.["email"]).should eq(["elvis@example.com"])
  end

  it "#create & #update" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    req_body = %({"email":"toby6@redant.com.au","banned":true,"extension_data":{"test":"data"}})
    created = Context(Guests, JSON::Any).response("POST", "#{GUESTS_BASE}/", body: req_body, headers: Mock::Headers.office365_guest, &.create)[1].as_h

    created["email"].should eq("toby6@redant.com.au")
    created["banned"].should eq(true)
    created["dangerous"].should eq(false)
    created["extension_data"].should eq({"test" => "data"})

    req_body = %({"email":"toby6@redant.com.au","dangerous":true,"extension_data":{"other":"info"}})
    updated = Context(Guests, JSON::Any).response("PATCH", "#{GUESTS_BASE}/toby6@redant.com.au", route_params: {"id" => "toby6@redant.com.au"}, body: req_body, headers: Mock::Headers.office365_guest, &.update)[1].as_h

    updated["email"].should eq("toby6@redant.com.au")
    updated["banned"].should eq(true)
    updated["dangerous"].should eq(true)
    updated["extension_data"].should eq({"test" => "data", "other" => "info"})

    guest = Guest.query.by_tenant(tenant.id).find!({email: updated["email"]})
    guest.extension_data.as_h.should eq({"test" => "data", "other" => "info"})
  end

  with_server do
    it "prevents duplicate guest emails on same tenant" do
      WebMock.allow_net_connect = true
      path = "/api/staff/v1/guests"
      req_body = %({"email":"toby@redant.com.au","banned":true,"extension_data":{"test":"data"}})

      curl(
        method: "POST",
        path: path,
        body: req_body,
        headers: Mock::Headers.office365_guest,
      )

      response = curl(
        method: "POST",
        path: path,
        body: req_body,
        headers: Mock::Headers.office365_guest,
      )

      response.status_code.should eq 422
      response.body.should contain "duplicate key value violates unique constraint"
    end

    it "creates guests with same emails on different tenants" do
      WebMock.allow_net_connect = true
      google_tenant = TenantsHelper.create_tenant({
        name:        "Ian",
        platform:    "google",
        domain:      "google.staff-api.dev",
        credentials: %({"issuer":"1122331212","scopes":["http://example.com"],"signing_key":"-----BEGIN PRIVATE KEY-----SOMEKEY DATA-----END PRIVATE KEY-----","domain":"example.com.au","sub":"jon@example.com.au"}),
      })
      GuestsHelper.create_guest(google_tenant.id, "Steve", "daniel@example.com")

      path = "/api/staff/v1/guests"
      req_body = %({"email":"daniel@example.com","banned":true,"extension_data":{"test":"data"}})

      response = curl(
        method: "POST",
        path: path,
        body: req_body,
        headers: Mock::Headers.office365_guest,
      )
      puts response.status_code.should eq 201
    end
    WebMock.reset
  end

  it "prevents duplicate guest emails on same tenant at the model level" do
    expect_raises(PQ::PQError, App::PG_UNIQUE_CONSTRAINT_REGEX) do
      tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
      GuestsHelper.create_guest(tenant.id, "Connor", "jon@example.com")
      GuestsHelper.create_guest(tenant.id, "Ian", "jon@example.com")
    end
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

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room2@example.com/calendar/calendarView?startDateTime=2020-08-30T14:00:00-00:00&endDateTime=2020-08-31T13:59:59-00:00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000008CD0441F4E7FD60100000000000000001000000087A54520ECE5BD4AA552D826F3718E7F%27&$top=10000")
      .to_return(GuestsHelper.mock_event_query_json)

    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Nathan", "nathan@redant.com.au")
    meta = EventMetadatasHelper.create_event(tenant.id, "generic_event")
    guest.attendee_for(meta.id.not_nil!)

    body = Context(Guests, JSON::Any).response("GET", "#{GUESTS_BASE}/#{guest.email}/meetings", route_params: {"id" => guest.email.not_nil!}, headers: Mock::Headers.office365_guest, &.meetings)[1].as_a
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
    [{
      "event_start" => 1598832000,
      "event_end"   => 1598833800,
      "id"          => "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAAB8_ORMAAA=",
      "host"        => "dev@acaprojects.onmicrosoft.com",
      "title"       => "My new meeting",
      "body"        => "The quick brown fox jumps over the lazy dog",
      "attendees"   => [
        {
          "name"            => "Toby Carvan",
          "email"           => "testing@redant.com.au",
          "response_status" => "needsAction",
          "resource"        => false,
          "extension_data"  => {} of String => String?,
        },
        {
          "name"            => "Amit Gaur",
          "email"           => "amit@redant.com.au",
          "response_status" => "needsAction",
          "resource"        => false,
          "extension_data"  => {} of String => String?,
        },
      ],
      "location"    => "",
      "private"     => true,
      "all_day"     => false,
      "timezone"    => "Australia/Sydney",
      "recurring"   => false,
      "attachments" => [] of String,
      "status"      => "confirmed",
      "creator"     => "dev@acaprojects.onmicrosoft.com",
    }]
  end

  def mock_event
    Office365::Event.new(**{
      starts_at:       Time.local,
      ends_at:         Time.local + 30.minutes,
      subject:         "My Unique Event Subject",
      rooms:           ["Red Room"],
      attendees:       ["elon@musk.com", Office365::EmailAddress.new(address: "david@bowie.net", name: "David Bowie"), Office365::Attendee.new(email: "the@goodies.org")],
      response_status: Office365::ResponseStatus.new(response: Office365::ResponseStatus::Response::Organizer, time: "0001-01-01T00:00:00Z"),
    })
  end

  def with_tz(event, tz : String = "UTC")
    event_response = JSON.parse(event).as_h
    event_response.merge({"originalStartTimeZone" => tz}).to_json
  end

  def mock_event_query_json
    {
      "value" => [JSON.parse(with_tz(mock_event.to_json))],
    }.to_json
  end
end
