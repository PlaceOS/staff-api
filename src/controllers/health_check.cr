class HealthCheck < ActionController::Base
  base "/api/staff/v1"

  def index
    render json: {
      commit:     App::BUILD_COMMIT,
      build_time: App::BUILD_TIME,
    }
  end
end
