class Events < Application
  base "/api/staff/v1/events"

  def index
    render json: {hello: "world"}
  end
end
