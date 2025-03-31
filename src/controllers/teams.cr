class Teams < Application
  base "/api/staff/v1/teams"

  # queue requests on a per-user basis
  @[AC::Route::Filter(:around_action)]
  Application.add_request_queue

  @[AC::Route::Filter(:before_action)]
  def get_teams_channel(teams_id : String, channel_id : String)
    @team = teams_id
    @channel = channel_id
  end

  getter! team : String
  getter! channel : String

  # returns the list of messages (without the replies) in a channel of a team.
  @[AC::Route::GET("/:teams_id/:channel_id")]
  def index(
    @[AC::Param::Info(name: "top", description: "optional number of channel messages to returned, default page size is 20", example: "20")]
    top : Int32? = nil,
  ) : ::Office365::ChatMessageList
    if client.client_id == :office365
      client.calendar.as(PlaceCalendar::Office365).client.list_channel_messages(team, channel, top: top)
    else
      raise Error::NotImplemented.new("Teams channel messages listing is not available for #{client.client_id}")
    end
  end

  # returns a single message or a message reply in a channel or a chat.
  @[AC::Route::GET("/:teams_id/:channel_id/:message_id")]
  def show(message_id : String) : Office365::ChatMessage
    if client.client_id == :office365
      client.calendar.as(PlaceCalendar::Office365).client.get_channel_message(team, channel, message_id)
    else
      raise Error::NotImplemented.new("getting teams single is not available for #{client.client_id}")
    end
  end

  # Send a new chatMessage in the specified channel or a chat.
  @[AC::Route::POST("/:teams_id/:channel_id", body: :message, status_code: HTTP::Status::CREATED)]
  def send_channel_message(message : String,
                           @[AC::Param::Info(name: "type", description: "optional message content type, default to TEXT", example: "HTML")]
                           content_type : String = "TEXT") : Nil
    if client.client_id == :office365
      client.calendar.as(PlaceCalendar::Office365).client.send_channel_message(team, channel, message, content_type)
    else
      raise Error::NotImplemented.new("sending teams channel chat message is not available for #{client.client_id}")
    end
  end
end
