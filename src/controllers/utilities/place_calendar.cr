module Utils::PlaceCalendar

  @client : PlaceCalendar? = nil

  def calendar
    @client ||= PlaceCalendar.new(tenant.place_calendar_params)
  end

end
