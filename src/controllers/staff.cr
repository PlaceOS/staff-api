class Staff < Application
  base "/api/staff/v1/people"

  def index
    query = params["q"]?
    render json: client.list_users(query)
  end

  def show
    id = params["id"]
    render json: client.get_user(id)
  end
end
