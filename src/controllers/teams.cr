# Teams, read and post messages in Microsoft Teams channels (Office365 only)
class Teams < Application
  base "/api/staff/v1/teams"

  # queue requests on a per-user basis
  @[AC::Route::Filter(:around_action)]
  Application.add_request_queue

  @[AC::Route::Filter(:before_action)]
  def get_teams_channel(
    @[AC::Param::Info(description: "the Microsoft Teams team id", example: "fbe2bf47-16c8-47cf-b4a5-4b9b187c508b")]
    teams_id : String,
    @[AC::Param::Info(description: "the channel id within the team", example: "19:4a95f7d8db4c4e7fae857bcebe0623e6@thread.tacv2")]
    channel_id : String,
  )
    @team = teams_id
    @channel = channel_id
  end

  getter! team : String
  getter! channel : String

  # Lists the messages (without their replies) in a Microsoft Teams channel.
  # Office365 only, returns 501 (not implemented) for Google.
  @[AC::Route::GET("/:teams_id/:channel_id")]
  def index(
    @[AC::Param::Info(name: "top", description: "optional number of channel messages to return, graph defaults to 20", example: "20")]
    top : Int32? = nil,
  ) : ::Office365::ChatMessageList
    raise Error::NotImplemented.new("Teams channel messages listing is not available for #{client.client_id}") unless client.client_id == :office365
    client.calendar.as(PlaceCalendar::Office365).client.list_channel_messages(team, channel, top: top)
  end

  # Returns a single message from a Microsoft Teams channel.
  # Office365 only, returns 501 (not implemented) for Google.
  @[AC::Route::GET("/:teams_id/:channel_id/:message_id")]
  def show(
    @[AC::Param::Info(description: "the id of the channel message", example: "1616965872395")]
    message_id : String,
  ) : Office365::ChatMessage
    raise Error::NotImplemented.new("getting teams single is not available for #{client.client_id}") unless client.client_id == :office365
    client.calendar.as(PlaceCalendar::Office365).client.get_channel_message(team, channel, message_id)
  end

  # Posts a new message to a Microsoft Teams channel as the current user, the request body is the message content.
  # Office365 only, returns 501 (not implemented) for Google.
  @[AC::Route::POST("/:teams_id/:channel_id", body: :message, status_code: HTTP::Status::CREATED)]
  def send_channel_message(message : String,
                           @[AC::Param::Info(name: "type", description: "the message content type, TEXT (default) or HTML", example: "HTML")]
                           content_type : String = "TEXT") : Nil
    raise Error::NotImplemented.new("sending teams channel chat message is not available for #{client.client_id}") unless client.client_id == :office365
    client.calendar.as(PlaceCalendar::Office365).client.send_channel_message(team, channel, message, content_type)
  end
end
