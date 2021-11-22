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
  end

  def stub_create_endpoints
    systems_json = File.read("./spec/fixtures/placeos/systems.json")
    systems_resp = Array(JSON::Any).from_json(systems_json).map &.to_json
    WebMock.stub(:get, ENV["PLACE_URI"].to_s + "/api/engine/v2/systems/sys-rJQQlR4Cn7")
      .to_return(body: systems_resp[0])
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev@acaprojects.onmicrosoft.com/calendar/events")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1@example.com/calendar/calendarView?startDateTime=2020-08-26T14:00:00-00:00&endDateTime=2020-08-27T13:59:59-00:00&%24filter=iCalUId+eq+%27040000008200E00074C5B7101A82E008000000006DE2E3761F8AD6010000000000000000100000009CCCDBB1F09DE74D8B157797D97F6A10%27&$top=10000")
      .to_return(GuestsHelper.mock_event_query_json)
    WebMock.stub(:get, "https://graph.microsoft.com/v1.0/users/room1@example.com/calendar/events/AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=")
      .to_return(body: File.read("./spec/fixtures/events/o365/create.json"))
  end

  def mock_event(id, event_start, event_end, system_id, room_email, host, ext_data)
    {
      "event_start" => event_start,
      "event_end"   => event_end,
      "id"          => id,
      "host"        => host,
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
        {"name"            => "Amit Gaur",
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
      "calendar"    => "room1@example.com",
      "system"      => {
        "created_at"           => 1562041110,
        "updated_at"           => 1562041120,
        "id"                   => system_id,
        "name"                 => "Room 1",
        "zones"                => ["zone-rGhCRp_aUD"],
        "modules"              => ["mod-rJRCVYKVuB", "mod-rJRGK21pya", "mod-rJRHYsZExU"],
        "email"                => room_email,
        "capacity"             => 10,
        "features"             => [] of String,
        "bookable"             => true,
        "installed_ui_devices" => 0,
        "version"              => 5,
      },
      "extension_data" => ext_data,
    }
  end

  def create_event_input
    %({
    "event_start": 1598503500,
    "event_end": 1598507160,
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

  def update_event_input1
    %({
    "event_start": 1598503500,
    "event_end": 1598507160,
    "extension_data": {
      "fizz": "buzz"
    }
    })
  end

  def create_event_output
    {
      "event_start" => 1598503500,
      "event_end"   => 1598507160,
      "id"          => "AAMkADE3YmQxMGQ2LTRmZDgtNDljYy1hNDg1LWM0NzFmMGI0ZTQ3YgBGAAAAAADFYQb3DJ_xSJHh14kbXHWhBwB08dwEuoS_QYSBDzuv558sAAAAAAENAAB08dwEuoS_QYSBDzuv558sAACGVOwUAAA=",
      "host"        => "dev@acaprojects.onmicrosoft.com",
      "title"       => "tentative event response status and default timezone trial updated",
      "body"        => "yeehaw hiya",
      "attendees"   => [
        {
          "name"            => "Amit",
          "email"           => "amit@redant.com.au",
          "response_status" => "accepted",
          "resource"        => false,
          "checked_in"      => false,
          "visit_expected"  => true,
          "extension_data"  => {} of String => String?,
        },
        {
          "name"            => "John",
          "email"           => "jon@example.com",
          "response_status" => "tentative",
          "resource"        => false,
          "checked_in"      => false,
          "visit_expected"  => true,
          "extension_data"  => {"fizz" => "buzz"},
        },
        {
          "name"            => "RM-AU-DP-L105-Swiss-Alps",
          "email"           => "rmaudpswissalps@booking.demo.acaengine.com",
          "response_status" => "needsAction",
          "resource"        => false,
          "extension_data"  => {} of String => String?,
        },
        {
          "name"            => "Developer",
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
      "extension_data" => {"foo" => "bar"},
    }
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
