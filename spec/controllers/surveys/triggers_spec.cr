require "../../spec_helper"
require "../helpers/spec_clean_up"
require "../helpers/survey_helper"
require "../helpers/booking_helper"

describe "Survey Triggers", tags: ["survey"] do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  pending "should create an invitation on booking state change" do
    survey = SurveyHelper.create_survey(
      zone_id: "zone-3",
      building_id: "zone-1",
      trigger: "RESERVED",
    )

    tenant = Tenant.query.find! { domain == "toby.staff-api.dev" }
    booking = BookingsHelper.create_booking(
      tenant_id: tenant.id,
      user_email: "user@example.com",
      zones: ["zone-1", "zone-2"],
    )

    invitations = Survey::Invitation.query.select("id").map(&.id)
    # pp "########################################"
    # pp! booking.current_state
    # pp! booking.history.map(&.state)
    # pp! invitations
    # pp "########################################"
  end
end
