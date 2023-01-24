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

  def mock_event_id(id)
    Office365::Event.new(**{
      id:              id,
      starts_at:       Time.unix(1598503500),
      ends_at:         Time.unix(1598507160),
      subject:         "My Unique Event Subject",
      rooms:           ["Red Room"],
      attendees:       ["elon@musk.com", Office365::EmailAddress.new(address: "david@bowie.net", name: "David Bowie"), Office365::Attendee.new(email: "the@goodies.org")],
      response_status: Office365::ResponseStatus.new(response: Office365::ResponseStatus::Response::Organizer, time: "0001-01-01T00:00:00Z"),
      recurrence:      Office365::RecurrenceParam.new(pattern: "daily", range_end: Time.unix(1598508160)),
    })
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

  def event_query_response(id)
    {
      "value" => [EventsHelper.mock_event_id(id)],
    }.to_json
  end

  def create_event_input
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
    "recurring": false,
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
