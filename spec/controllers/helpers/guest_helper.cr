module GuestsHelper
  extend self

  def create_guest(tenant_id)
    create_guest(tenant_id, Faker::Internet.email)
  end

  def create_guest(tenant_id, email)
    create_guest(tenant_id, Faker::Name.name, email)
  end

  def create_guest(tenant_id, name, email)
    Guest.new(
      name: name,
      email: email,
      tenant_id: tenant_id,
      banned: false,
      dangerous: false,
    ).save!
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
