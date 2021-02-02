class HealthCheck < Application
  base "/api/staff/v1"

  def index
    head :ok
  end
end
