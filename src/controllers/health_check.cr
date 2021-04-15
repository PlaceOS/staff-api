class HealthCheck < ActionController::Base
  base "/api/staff/v1"

  def index
    Clear::Migration::Manager.instance.load_existing_migrations
    render json: {
      commit:     App::BUILD_COMMIT,
      build_time: App::BUILD_TIME,
    }
  end
end
