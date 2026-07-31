module EventsHelper
  extend self

  def stub_event_tokens
    WebMock.stub(:post, "https://login.microsoftonline.com/bb89674a-238b-4b7d-91ec-6bebad83553a/oauth2/v2.0/token")
      .to_return(body: File.read("./spec/fixtures/tokens/o365_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/auth/oauth/token")
      .to_return(body: File.read("./spec/fixtures/tokens/placeos_token.json"))
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/event/changed")
      .to_return(body: "")
    WebMock.stub(:post, "#{ENV["PLACE_URI"]}/api/engine/v2/signal?channel=staff/guest/attending")
      .to_return(body: "")
    systems_json = File.read("./spec/fixtures/placeos/systems.json")
    systems_resp = Array(JSON::Any).from_json(systems_json).map &.to_json
    WebMock.stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/sys-rJQQlR4Cn7")
      .to_return(body: systems_resp[0])
  end

  def stub_create_endpoints
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    stub_show_endpoints
  end

  def stub_show_endpoints
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendar?")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.com/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
  end

  # Everything Graph needs stubbed to create an event and then PATCH it.
  def stub_update_endpoints
    stub_create_endpoints

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:patch, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA%3D")
      .to_return(body: File.read("./spec/fixtures/events/o365/update.json"))
    # the host's copy of the event, looked up by ical uid
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/calendarView?startDateTime=2020-08-26T14%3A00%3A00-00%3A00&endDateTime=2020-08-27T13%3A59%3A59-00%3A00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&%24top=10000")
      .to_return(body: File.read("./spec/fixtures/events/o365/events_query.json"))
  end

  # Lets `can_create?` see the requesting user as a delegate of `mailbox`, so a
  # meeting can be re-sent from their calendar.
  def stub_calendar_write_access(mailbox : String, user = "dev@acaprojects.onmicrosoft.com")
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/#{URI.encode_path_segment(user)}/calendars")
      .to_return(body: File.read("./spec/fixtures/calendars/o365/show.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/#{URI.encode_path_segment(mailbox)}/calendar/calendarPermissions")
      .to_return(body: {value: [{
        id:                   "permission-1",
        role:                 "write",
        isRemovable:          true,
        isInsideOrganization: true,
        allowedRoles:         ["write"],
        emailAddress:         {address: user, name: user},
      }]}.to_json)
  end

  # The room's copy of the event, looked up by ical uid once the id is known.
  def stub_room_event_query(event_id)
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/calendarView?startDateTime=2020-08-26T14:00:00-00:00&endDateTime=2020-08-27T13:59:59-00:00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&$top=10000")
      .to_return(event_query_response(event_id))
  end

  # An update body with a configurable host and host_override, for exercising
  # host reassignment on an existing event.
  def reassign_host_input(host = "dev@acaprojects.onmicrosoft.com", host_override : String? = nil, extra_attendee : String? = nil, attendee = "amit@redant.com.au", system_id = "sys-rJQQlR4Cn7")
    extension_data = host_override.nil? ? %({"fizz": "buzz"}) : %({"fizz": "buzz", "host_override": "#{host_override}"})
    attendees = [%({
            "name": "Amit",
            "email": "#{attendee}",
            "response_status": "accepted",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true
        })]
    if extra_attendee
      attendees << %({
            "name": "New Guest",
            "email": "#{extra_attendee}",
            "response_status": "tentative",
            "resource": false,
            "organizer": false,
            "checked_in": false,
            "visit_expected": true
        })
    end

    %({
    "event_start": 1598504460,
    "event_end": 1598508120,
    "attendees": [#{attendees.join(",")}],
    "private": false,
    "all_day": false,
    "recurring": false,
    "host": "#{host}",
    "title": "tentative event response status and default timezone trial",
    "body": "yeehaw hiya updated",
    "location": "test",
    "system_id": "#{system_id}",
    "system": {
        "id": "#{system_id}"
    },
    "extension_data": #{extension_data}
    })
  end

  # The ical uid carried by the o365 event fixtures.
  ICAL_UID = "040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10"

  def mock_event_id(id, ical = nil, recurring = true, organizer : String? = nil)
    event = Office365::Event.new(**{
      organizer:       organizer,
      id:              id,
      starts_at:       Time.unix(1598503500),
      ends_at:         Time.unix(1598507160),
      subject:         "My Unique Event Subject",
      rooms:           ["Red Room"],
      attendees:       ["elon@musk.com", Office365::EmailAddress.new(address: "david@bowie.net", name: "David Bowie"), Office365::Attendee.new(email: "the@goodies.org")],
      response_status: Office365::ResponseStatus.new(response: Office365::ResponseStatus::Response::Organizer, time: "0001-01-01T00:00:00Z"),
      recurrence:      (Office365::RecurrenceParam.new(pattern: "daily", range_end: Time.unix(1598508160)) if recurring),
    })
    event.icaluid = ical
    event
  end

  # The event id carried by the o365 event fixtures.
  FIXTURE_EVENT_ID = "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA="

  # Serves the event as a one-off rather than a recurring series, on both the
  # room's and the host's calendar. Register before the shared stubs.
  def stub_one_off_event(event_id = FIXTURE_EVENT_ID, host = "dev@acaprojects.onmicrosoft.com")
    event = mock_event_id(event_id, ICAL_UID, recurring: false, organizer: host).to_json

    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1%40example.com/calendar/events/#{URI.encode_path_segment(event_id)}")
      .to_return(body: event)
    # the host's copy is looked up over the event's day, which this event spans
    # in UTC rather than in the fixture's timezone
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/#{URI.encode_path_segment(host)}/calendar/calendarView?startDateTime=2020-08-27T00%3A00%3A00-00%3A00&endDateTime=2020-08-27T23%3A59%3A59-00%3A00&%24filter=iCalUId+eq+%27#{ICAL_UID}%27&%24top=10000")
      .to_return(body: %({"value": [#{event}]}))
  end

  def stub_permissions_check(system_id)
    WebMock.stub(:get, "http://toby.dev.place.tech/api/engine/v2/metadata/#{system_id}?name=permissions")
      .to_return(body: %({
        "permissions": {
          "name": "permissions",
          "description": "",
          "parent_id": "#{system_id}",
          "details": {
            "admin": ["#{system_id}", "admin"]
          }
        }
      }))

    WebMock.stub(:get, "http://toby.dev.place.tech/api/engine/v2/metadata/zone-rGhCRp_aUD?name=permissions")
      .to_return(body: %({
        "permissions": {
          "name": "permissions",
          "description": "",
          "parent_id": "zone-rGhCRp_aUD",
          "details": {
            "admin": ["#{system_id}", "admin"]
          }
        }
      }))
  end

  def event_query_response(id, ical = nil)
    {
      "value" => [EventsHelper.mock_event_id(id, ical)],
    }.to_json
  end

  def create_event_input(user = Mock::Token.generate_auth_user(false, false), permission = PlaceOS::Model::EventMetadata::Permission::PRIVATE)
    %({
    "event_start": 1598503500,
    "event_end": 1598507160,
    "recurrence": {"range_start":1637825922,"range_end":1639035522,"interval":2,"pattern":"daily"},
    "attendees": [
         {
            "name": "Amit",
            "email": "#{user.email}",
            "response_status": "accepted",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true
        },
        {
            "name": "John",
            "preferred_name": "Jon",
            "phone": "012334446",
            "organisation": "Google inc",
            "photo": "http://example.com/first.jpg",
            "email": "jon@example.com",
            "response_status": "tentative",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true,
            "extension_data": {
                "fizz": "buzz"
            },
            "notes": "some notes"
        }
    ],
    "private": false,
    "all_day": false,
    "recurring": false,
    "host": "dev@acaprojects.onmicrosoft.com",
    "title": "tentative event response status and default timezone trial updated",
    "body": "yeehaw hiya",
    "location": "test",
    "system_id": "sys-rJQQlR4Cn7",
    "system": {
        "id": "sys-rJQQlR4Cn7"
    },
    "permission": "#{permission}",
    "extension_data": {
      "foo": "bar"
    }
    })
  end

  def create_recurring_event_input
    %({
    "event_start": 1598503500,
    "event_end": 1598507160,
    "recurrence": {"range_start":1637825922,"range_end":1639035522,"interval":2,"pattern":"daily"},
    "attendees": [
         {
            "name": "Amit",
            "email": "amit@redant.com.au",
            "response_status": "accepted",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true
        },
        {
            "name": "John",
            "preferred_name": "Jon",
            "phone": "012334446",
            "organisation": "Google inc",
            "photo": "http://example.com/first.jpg",
            "email": "jon@example.com",
            "response_status": "tentative",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true,
            "extension_data": {
                "fizz": "buzz"
            },
            "notes": "some notes"
        }
    ],
    "private": false,
    "all_day": false,
    "host": "dev@acaprojects.onmicrosoft.com",
    "title": "tentative event response status and default timezone trial updated",
    "body": "yeehaw hiya",
    "location": "test",
    "system_id": "sys-rJQQlR4Cn7",
    "system": {
        "id": "sys-rJQQlR4Cn7"
    },
    "extension_data": {
      "foo": "bar"
    }
    })
  end

  def update_event_input
    %({
    "event_start": 1598504460,
    "event_end": 1598508120,
    "attendees": [
         {
            "name": "Amit",
            "email": "amit@redant.com.au",
            "response_status": "accepted",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true,
            "extension_data": {
                "fuzz": "bizz"
            }
        },
        {
            "name": "Robert",
            "preferred_name": "bob",
            "phone": "012333336",
            "organisation": "Apple inc",
            "photo": "http://example.com/bob.jpg",
            "email": "bob@example.com",
            "response_status": "tentative",
            "resource": false,
            "organizer": true,
            "checked_in": true,
            "visit_expected": true,
            "extension_data": {
                "buzz": "fuzz"
            },
            "notes": "some updated notes"
        }
    ],
    "private": false,
    "all_day": false,
    "recurring": false,
    "host": "dev@acaprojects.onmicrosoft.com",
    "title": "tentative event response status and default timezone trial",
    "body": "yeehaw hiya updated",
    "location": "test",
    "system_id": "sys-rJQQlR4Cn7",
    "system": {
        "id": "sys-rJQQlR4Cn7"
    },
    "extension_data": {
      "fizz": "buzz"
    }
    })
  end

  def update_event_output
    {
      "event_start" => 1598504460,
      "event_end"   => 1598508120,
      "id"          => "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=",
      "host"        => "dev@acaprojects.onmicrosoft.com",
      "title"       => "tentative event response status and default timezone trial",
      "body"        => "yeehaw hiya updated",
      "attendees"   => [
        {
          "name"            => "Amit",
          "email"           => "amit@redant.com.au",
          "response_status" => "accepted",
          "resource"        => false,
          "checked_in"      => false,
          "visit_expected"  => true,
          "extension_data"  => {
            "fuzz" => "bizz",
          },
        },
        {"name"            => "Robert",
         "email"           => "bob@example.com",
         "response_status" => "tentative",
         "resource"        => false,
         "checked_in"      => false,
         "visit_expected"  => true,
         "extension_data"  => {
           "buzz" => "fuzz",
         },
        },
        {"name"            => "RM-AU-DP-L105-Swiss-Alps",
         "email"           => "rmaudpswissalps@booking.demo.acaengine.com",
         "response_status" => "needsAction",
         "resource"        => false,
         "extension_data"  => {} of String => String?,
        },
        {"name"            => "Developer",
         "email"           => "dev@acaprojects.onmicrosoft.com",
         "response_status" => "accepted",
         "resource"        => false,
         "checked_in"      => false,
         "visit_expected"  => true,
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
      "calendar"    => "room1@example.com",
      "system"      => {
        "created_at"           => 1562041110,
        "updated_at"           => 1562041120,
        "id"                   => "sys-rJQQlR4Cn7",
        "name"                 => "Room 1",
        "zones"                => ["zone-rGhCRp_aUD"],
        "modules"              => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"],
        "email"                => "room1@example.com",
        "capacity"             => 10,
        "features"             => [] of String,
        "bookable"             => true,
        "installed_ui_devices" => 0,
        "version"              => 5,
      },
      "extension_data" => {"foo" => "bar", "fizz" => "buzz"},
    }
  end

  def guests_list_output
    [
      {"email"          => "amit@redant.com.au",
       "name"           => "Amit",
       "preferred_name" => nil,
       "phone"          => nil,
       "organisation"   => nil,
       "notes"          => nil,
       "photo"          => nil,
       "banned"         => false,
       "dangerous"      => false,
       "extension_data" => {} of String => String?,
       "checked_in"     => false,
       "visit_expected" => true,
      },
      {
        "email"          => "jon@example.com",
        "name"           => "John",
        "preferred_name" => "Jon",
        "phone"          => "012334446",
        "organisation"   => "Google inc",
        "notes"          => "some notes",
        "photo"          => "http://example.com/first.jpg",
        "banned"         => false,
        "dangerous"      => false,
        "extension_data" => {"fizz" => "buzz"},
        "checked_in"     => false,
        "visit_expected" => true,
      },
      {
        "email"          => "dev@acaprojects.onmicrosoft.com",
        "name"           => "dev@acaprojects.onmicrosoft.com",
        "preferred_name" => nil,
        "phone"          => nil,
        "organisation"   => nil,
        "notes"          => nil,
        "photo"          => nil,
        "banned"         => false,
        "dangerous"      => false,
        "extension_data" => {} of String => String?,
        "checked_in"     => false,
        "visit_expected" => true,
      },
    ]
  end
end
