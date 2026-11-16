# Stubs Office365 free/busy (getSchedule) for the spec user, dev@acaprojects.onmicrosoft.com
module ScheduleHelper
  extend self

  ME = "dev@acaprojects.onmicrosoft.com"

  # `busy` maps a calendar to its busy periods. Returns the calendars each request asked for.
  # Stub once per example: WebMock answers with the first matching stub
  def stub(busy : Hash(String, Array(Tuple(Time, Time)))) : Array(Array(String))
    requested = [] of Array(String)
    WebMock.stub(:post, "https://graph.microsoft.com/v1.0/users/dev%40acaprojects.onmicrosoft.com/calendar/getSchedule").to_return do |request|
      schedules = JSON.parse(request.body.try(&.gets_to_end) || "{}")["schedules"].as_a.map(&.as_s)
      requested << schedules
      HTTP::Client::Response.new(200, body: response(schedules, busy), headers: HTTP::Headers{"Content-Type" => "application/json"})
    end
    requested
  end

  private def response(schedules : Array(String), busy : Hash(String, Array(Tuple(Time, Time)))) : String
    format = "%Y-%m-%dT%H:%M:%S.0000000"
    {
      value: schedules.map do |calendar|
        {
          scheduleId:    calendar,
          scheduleItems: (busy[calendar]? || [] of Tuple(Time, Time)).map do |(starting, ending)|
            {
              isPrivate: false,
              status:    "busy",
              start:     {dateTime: starting.to_utc.to_s(format), timeZone: "Coordinated Universal Time"},
              end:       {dateTime: ending.to_utc.to_s(format), timeZone: "Coordinated Universal Time"},
            }
          end,
        }
      end,
    }.to_json
  end
end
