require "place_calendar"

module Utils::PlaceCalendar

  @client : PlaceCalendar? = nil

  def client
    @client ||= ::PlaceCalendar::Client.new(tenant.place_calendar_params)
  end

end
