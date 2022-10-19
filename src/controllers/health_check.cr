class HealthCheck < ActionController::Base
  base "/api/staff/v1"

  struct BuildInfo
    include JSON::Serializable
    include AutoInitialize

    getter commit : String
    getter build_time : String
  end

  # returns the service build details
  @[AC::Route::GET("/")]
  def index : BuildInfo
    Clear::Migration::Manager.instance.load_existing_migrations
    BuildInfo.new(commit: App::BUILD_COMMIT, build_time: App::BUILD_TIME)
  end
end
