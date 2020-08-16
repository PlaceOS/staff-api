module Utils::PlaceCalendar

  @calendar : PlaceCalendar? = nil

  def calendar
    @calendar ||= PlaceCalendar.new(tenant.place_calendar_params)
  end

end
