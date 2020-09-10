require "../spec_helper"

describe Guests do
  Spec.after_each do
    Guest.query.each { |record| record.delete }
    EventMetadata.query.each { |record| record.delete }
  end
  systems_json = File.read("./spec/fixtures/placeos/systems.json")
  systems_resp = Array(JSON::Any).from_json(systems_json).map &.to_json

  it "#index unfiltered should return a list of all guests" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
    GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

    response = IO::Memory.new
    Guests.new(context("GET", "/api/staff/v1/guests", OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)

    guest_names = results.as_a.map { |r| r["name"] }
    guest_emails = results.as_a.map { |r| r["email"] }
    guest_names.should eq(["Jon", "Steve"])
    guest_emails.should eq(["jon@example.com", "steve@example.com"])
  end

  it "#index query filtered should return a list of only matched guests" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    GuestsHelper.create_guest(tenant.id, "Jon", "jon@example.com")
    GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

    response = IO::Memory.new
    Guests.new(context("GET", "/api/staff/v1/guests?q=steve", OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)

    guest_names = results.as_a.map { |r| r["name"] }
    guest_emails = results.as_a.map { |r| r["email"] }
    guest_names.should eq(["Steve"])
    guest_emails.should eq(["steve@example.com"])
  end

  it "#index should return guests visiting today" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")

    now = Time.utc.to_unix
    later = 4.hours.from_now.to_unix
    route = "/api/staff/v1/guests?period_start=#{now}&period_end=#{later}"
    response = IO::Memory.new
    Guests.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    results.should eq([] of String)

    meta = EventMetadatasHelper.create_event(tenant.id, "generic_event")
    guest.attendee_for(meta.id.not_nil!)

    response = IO::Memory.new
    Guests.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index
    results = extract_json(response)
    guest_names = results.as_a.map { |r| r["name"] }
    guest_emails = results.as_a.map { |r| r["email"] }
    guest_names.should eq(["Toby"])
    guest_emails.should eq(["toby@redant.com.au"])
  end

  it "#index should return guests visiting today in a subset of rooms" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
    meta = EventMetadatasHelper.create_event(tenant.id, "generic_event")
    guest.attendee_for(meta.id.not_nil!)

    {"sys-rJQQlR4Cn7", "sys_id"}.each_with_index do |system_id, index|
      WebMock
        .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
        .to_return(body: systems_resp[index])
    end
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/index.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))

    now = Time.utc.to_unix
    later = 4.hours.from_now.to_unix
    route = "/api/staff/v1/guests?period_start=#{now}&period_end=#{later}&system_ids=sys-rJQQlR4Cn7"
    response = IO::Memory.new
    Guests.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    results.should eq([] of String)

    response = IO::Memory.new
    route = "/api/staff/v1/guests?period_start=#{now}&period_end=#{later}&system_ids=sys-rJQQlR4Cn7,sys_id"
    Guests.new(context("GET", route, OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)
    guest_names = results.as_a.map { |r| r["name"] }
    guest_emails = results.as_a.map { |r| r["email"] }
    guest_names.should eq(["Toby"])
    guest_emails.should eq(["toby@redant.com.au"])
  end

  it "#show should show a guests details" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))

    response = IO::Memory.new
    context = context("GET", "/api/staff/v1/guests/#{guest.email}/", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => guest.email.not_nil!}
    Guests.new(context).show


    results = extract_json(response)

    results.as_h["name"].should eq("Toby")
    results.as_h["email"].should eq("toby@redant.com.au")
    results.as_h["visit_expected"].should eq(false)
  end

  it "#show should show a guests details when visting today" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
    meta = EventMetadatasHelper.create_event(tenant.id, "128912891829182")
    guest.attendee_for(meta.id.not_nil!)

    response = IO::Memory.new
    context = context("GET", "/api/staff/v1/guests/#{guest.email}/", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => guest.email.not_nil!}
    Guests.new(context).show

    results = extract_json(response)

    results.as_h["name"].should eq("Toby")
    results.as_h["email"].should eq("toby@redant.com.au")
    results.as_h["visit_expected"].should eq(true)
  end

  it "#destroy should delete a guest" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    toby = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
    steve = GuestsHelper.create_guest(tenant.id, "Steve", "steve@example.com")

    context = context("DELETE", "/api/staff/v1/guests/#{toby.email}/", OFFICE365_HEADERS)
    context.route_params = {"id" => toby.email.not_nil!}
    Guests.new(context).destroy

    # Check only one is returned
    response = IO::Memory.new
    Guests.new(context("GET", "/api/staff/v1/guests", OFFICE365_HEADERS, response_io: response)).index

    results = extract_json(response)

    # Only has steve, toby got deleted
    guest_names = results.as_a.map { |r| r["name"] }
    guest_emails = results.as_a.map { |r| r["email"] }
    guest_names.should eq(["Steve"])
    guest_emails.should eq(["steve@example.com"])
  end

  it "#create should create and #update should update a guest" do
    body = IO::Memory.new
    body << %({"email":"toby@redant.com.au","banned":true,"extension_data":{"test":"data"}})
    body.rewind
    response = IO::Memory.new
    context = context("POST", "/api/staff/v1/guests/", OFFICE365_HEADERS, body, response_io: response)
    Guests.new(context).create
    create_results = extract_json(response)

    create_results.as_h["email"].should eq("toby@redant.com.au")
    create_results.as_h["banned"].should eq(true)
    create_results.as_h["dangerous"].should eq(false)
    create_results.as_h["extension_data"].should eq({"test" => "data"})

    body = IO::Memory.new
    body << %({"email":"toby@redant.com.au","dangerous":true,"extension_data":{"other":"info"}})
    body.rewind
    response = IO::Memory.new
    context = context("PATCH", "/api/staff/v1/guests/toby@redant.com.au", OFFICE365_HEADERS, body, response_io: response)
    context.route_params = {"id" => "toby@redant.com.au"}
    Guests.new(context).update
    update_results = extract_json(response)

    update_results.as_h["email"].should eq("toby@redant.com.au")
    update_results.as_h["banned"].should eq(true)
    update_results.as_h["dangerous"].should eq(true)
    update_results.as_h["extension_data"].should eq({"test" => "data", "other" => "info"})
  end

  it "#meetings should show meetings for guest" do
    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    guest = GuestsHelper.create_guest(tenant.id, "Toby", "toby@redant.com.au")
    meta = EventMetadatasHelper.create_event(tenant.id, "generic_event")
    guest.attendee_for(meta.id.not_nil!)

    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.com/calendar/events/generic_event")
      .to_return(body: File.read("./spec/fixtures/events/o365/generic_event.json"))
    {"sys-rJQQlR4Cn7", "sys_id"}.each_with_index do |system_id, index|
      WebMock
        .stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/#{system_id}")
        .to_return(body: systems_resp[index])
    end

    response = IO::Memory.new
    context = context("GET", "/api/staff/v1/guests/#{guest.email}/meetings", OFFICE365_HEADERS, response_io: response)
    context.route_params = {"id" => guest.email.not_nil!}
    Guests.new(context).meetings

    results = extract_json(response)

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
end
