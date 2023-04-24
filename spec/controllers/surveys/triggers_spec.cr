require "../../spec_helper"
require "../helpers/survey_helper"
require "../helpers/booking_helper"

describe "Survey Triggers", tags: ["survey"] do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  before_each do
    # Booking.query.each(&.delete)
    Booking.truncate
    Survey.truncate
    Survey::Invitation.truncate
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/booking/changed")
      .to_return(body: "")

    Timecop.scale(600) # 1 second == 10 minutes
  end

  after_all do
    WebMock.reset
    Timecop.scale(1)
  end

  it "should create an invitation on RESERVED trigger" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-2",
      building_id: "zone-1",
      trigger: Survey::TriggerType::RESERVED,
    )

    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id.not_nil!,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
    )
    invitations = Survey::Invitation.select("id").map(&.id)
    invitations.size.should eq(1)
  end

  it "should create an invitation on CHECKEDIN trigger" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-2",
      building_id: "zone-1",
      trigger: Survey::TriggerType::CHECKEDIN,
    )

    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id.not_nil!,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 9.minutes.from_now.to_unix,
    )

    client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=true", headers: headers)

    invitations = Survey::Invitation.select("id").map(&.id)
    invitations.size.should eq(1)
  end

  it "should create an invitation on CHECKEDOUT trigger" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-2",
      building_id: "zone-1",
      trigger: Survey::TriggerType::CHECKEDOUT,
    )

    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id.not_nil!,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 9.minutes.from_now.to_unix,
    )

    client.post("#{BOOKINGS_BASE}/#{booking.id}/check_in?state=false", headers: headers)

    invitations = Survey::Invitation.select("id").map(&.id)
    invitations.size.should eq(1)
  end

  it "should create an invitation on REJECTED trigger" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-2",
      building_id: "zone-1",
      trigger: Survey::TriggerType::REJECTED,
    )

    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id.not_nil!,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 9.minutes.from_now.to_unix,
    )

    client.post("#{BOOKINGS_BASE}/#{booking.id}/reject", headers: headers)

    invitations = Survey::Invitation.select("id").map(&.id)
    invitations.size.should eq(1)
  end

  it "should create an invitation on CANCELLED trigger" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-2",
      building_id: "zone-1",
      trigger: Survey::TriggerType::CANCELLED,
    )

    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id.not_nil!,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 9.minutes.from_now.to_unix,
    )

    client.delete("#{BOOKINGS_BASE}/#{booking.id}", headers: headers)

    invitations = Survey::Invitation.select("id").map(&.id)
    invitations.size.should eq(1)
  end

  it "should create an invitation on VISITOR_CHECKEDIN trigger" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-2",
      building_id: "zone-1",
      trigger: Survey::TriggerType::VISITOR_CHECKEDIN,
    )

    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id.not_nil!,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 9.minutes.from_now.to_unix,
    )
    guest = Guest.create!(
      name: Faker::Name.name,
      email: "visitor@example.com",
      tenant_id: tenant.id,
      banned: false,
      dangerous: false,
    )
    visitor = Attendee.create!(
      tenant_id: guest.tenant_id,
      booking_id: booking.id,
      guest_id: guest.id,
      checked_in: false,
      visit_expected: true,
    )

    visitor.checked_in = true
    visitor.save!

    invitations = Survey::Invitation.select("id").map(&.id)
    invitations.size.should eq(1)
  end

  pending "should create an invitation on VISITOR_CHECKEDOUT trigger" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-2",
      building_id: "zone-1",
      trigger: Survey::TriggerType::VISITOR_CHECKEDOUT,
    )

    tenant = Tenant.find_by(domain: "toby.staff-api.dev")
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id.not_nil!,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
      booking_start: 1.minutes.from_now.to_unix,
      booking_end: 9.minutes.from_now.to_unix,
    )
    guest = Guest.create!(
      name: Faker::Name.name,
      email: "visitor@example.com",
      tenant_id: tenant.id,
      banned: false,
      dangerous: false,
    )
    visitor = Attendee.create!(
      tenant_id: guest.tenant_id,
      booking_id: booking.id,
      guest_id: guest.id,
      checked_in: true,
      visit_expected: true,
    )

    visitor.checked_in = false
    visitor.save!

    invitations = Survey::Invitation.select("id").map(&.id)
    invitations.size.should eq(1)
  end
end
