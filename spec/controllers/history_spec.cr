require "../spec_helper"
require "./helpers/booking_helper"

describe "change history" do
  client = AC::SpecHelper.client

  it "attributes changes to the client of the request" do
    History.clear
    headers = Mock::Headers.office365_guest
    headers["X-App-Name"] = "workplace"
    headers["X-App-Build"] = "abc123"
    headers["User-Agent"] = "Spec Browser"

    starting = 10.minutes.from_now.to_unix
    ending = 30.minutes.from_now.to_unix
    response = client.post(BOOKINGS_BASE, headers: headers,
      body: %({"asset_id":"desk-history","booking_start":#{starting},"booking_end":#{ending},"booking_type":"desk"}))
    response.status_code.should eq(201)
    booking_id = JSON.parse(response.body)["id"].to_s

    entry = History.for_resource(Booking.table_name, booking_id).to_a.first
    entry.action.should eq "create"
    metadata = entry.metadata
    metadata.app_name.should eq "workplace"
    metadata.app_build.should eq "abc123"
    metadata.user_agent.should eq "Spec Browser"
    metadata.request_id.should eq response.headers["X-Request-ID"]

    History.current_metadata.should be_nil
  end
end
