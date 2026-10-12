require "../spec_helper"
require "./helpers/booking_helper"
require "./helpers/event_helper"

# The small tools the MCP cards (and models) use instead of the full update and create routes
describe "lean tools" do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "Bookings#edit" do
    before_each do
      Booking.clear
      Attendee.truncate
      Guest.truncate
    end

    it "changes a booking's title, description and times" do
      owner = "lean-owner@example.com"
      owner_headers = HTTP::Headers{"Host" => "toby.staff-api.dev", "Authorization" => "Bearer #{Mock::Token.normal_office_user(owner)}"}
      booking = BookingsHelper.create_booking(get_tenant.id.not_nil!, owner)
      starting = 2.hours.from_now.to_unix
      ending = 3.hours.from_now.to_unix

      response = client.patch("#{Bookings.base_route}/#{booking.id}/edit?title=Focus&description=window&booking_start=#{starting}&booking_end=#{ending}", headers: owner_headers)
      response.status_code.should eq 200
      body = JSON.parse(response.body)
      body["title"].should eq "Focus"
      body["description"].should eq "window"
      body["booking_start"].should eq starting
      body["booking_end"].should eq ending

      saved = Booking.find(booking.id.not_nil!)
      saved.title.should eq "Focus"
      saved.booking_start.should eq starting
    end

    it "leaves the fields that aren't provided" do
      booking = BookingsHelper.create_booking(get_tenant.id.not_nil!, "lean-owner@example.com")
      response = client.patch("#{Bookings.base_route}/#{booking.id}/edit?title=Renamed", headers: headers)
      response.status_code.should eq 200
      saved = Booking.find(booking.id.not_nil!)
      saved.title.should eq "Renamed"
      saved.booking_start.should eq booking.booking_start
      saved.booking_end.should eq booking.booking_end
    end

    it "requires a change" do
      booking = BookingsHelper.create_booking(get_tenant.id.not_nil!, "lean-owner@example.com")
      client.patch("#{Bookings.base_route}/#{booking.id}/edit", headers: headers).status_code.should eq 400
    end

    it "is forbidden to people who don't own the booking" do
      booking = BookingsHelper.create_booking(get_tenant.id.not_nil!, "lean-owner@example.com")
      other = HTTP::Headers{"Host" => "toby.staff-api.dev", "Authorization" => "Bearer #{Mock::Token.normal_office_user("lean-other@example.com")}"}
      client.patch("#{Bookings.base_route}/#{booking.id}/edit?title=Mine", headers: other).status_code.should eq 403
      Booking.find(booking.id.not_nil!).title.should_not eq "Mine"
    end
  end

  describe "Events#book and Events#edit" do
    system_id = "sys-rJQQlR4Cn7"
    event_id = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA="

    # captures the bodies sent to Office365, WebMock matches the first stub registered
    stub_graph = -> do
      WebMock.reset
      posted = [] of String
      patched = [] of String
      WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
        .to_return do |request|
          posted << (request.body.try(&.gets_to_end) || "")
          HTTP::Client::Response.new(200, body: File.read("./spec/fixtures/events/o365/create.json"))
        end
      WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/#{URI.encode_www_form(event_id)}")
        .to_return do |request|
          patched << (request.body.try(&.gets_to_end) || "")
          HTTP::Client::Response.new(200, body: File.read("./spec/fixtures/events/o365/update.json"))
        end
      EventsHelper.stub_event_tokens
      EventsHelper.stub_update_endpoints
      EventsHelper.stub_room_event_query(event_id)
      {posted, patched}
    end

    before_each do
      EventMetadata.truncate
      Guest.truncate
      Attendee.truncate
    end

    it "books a meeting in a room with attendees" do
      posted, _patched = stub_graph.call
      starting = 1.day.from_now.to_unix
      ending = starting + 1800

      response = client.post("#{Events.base_route}/book?title=Catch%20up&event_start=#{starting}&event_end=#{ending}&system_id=#{system_id}&attendees=jon@example.com", headers: headers)
      response.status_code.should eq 201

      sent = JSON.parse(posted.last)
      sent["subject"].should eq "Catch up"
      emails = sent["attendees"].as_a.map(&.["emailAddress"]["address"].as_s)
      emails.should contain "jon@example.com"
      emails.should contain "room1@example.com"

      EventMetadata.find_by(event_id: JSON.parse(response.body)["id"].as_s).system_id.should eq system_id
    end

    it "accepts attendees as a JSON array, as MCP clients send them" do
      posted, _patched = stub_graph.call
      starting = 1.day.from_now.to_unix
      attendees = URI.encode_www_form(%(["jon@example.com","amy@example.com"]))

      response = client.post("#{Events.base_route}/book?title=Sync&event_start=#{starting}&event_end=#{starting + 1800}&attendees=#{attendees}", headers: headers)
      response.status_code.should eq 201
      emails = JSON.parse(posted.last)["attendees"].as_a.map(&.["emailAddress"]["address"].as_s)
      emails.should contain "jon@example.com"
      emails.should contain "amy@example.com"
    end

    it "changes a meeting's title and keeps the rest" do
      _posted, patched = stub_graph.call

      response = client.patch("#{Events.base_route}/#{URI.encode_path_segment(event_id)}/edit?system_id=#{system_id}&title=Renamed", headers: headers)
      response.status_code.should eq 200

      sent = JSON.parse(patched.last)
      sent["subject"].should eq "Renamed"
      emails = sent["attendees"].as_a.map(&.["emailAddress"]["address"].as_s.downcase)
      # the existing attendees and the room are kept
      emails.should contain "amit@redant.com.au"
      emails.should contain "room1@example.com"
    end

    it "replaces the people invited, keeping the room" do
      _posted, patched = stub_graph.call

      response = client.patch("#{Events.base_route}/#{URI.encode_path_segment(event_id)}/edit?system_id=#{system_id}&attendees=new-person@example.com", headers: headers)
      response.status_code.should eq 200

      emails = JSON.parse(patched.last)["attendees"].as_a.map(&.["emailAddress"]["address"].as_s.downcase)
      emails.should contain "new-person@example.com"
      emails.should contain "room1@example.com"
      emails.should_not contain "amit@redant.com.au"
    end
  end
end
