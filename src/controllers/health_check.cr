class HealthCheck < ActionController::Base
  base "/api/staff/v1"

  record BuildInfo, commit : String, build_time : String do
    include JSON::Serializable
  end

  # returns the service build details
  @[AC::Route::GET("/")]
  def index : BuildInfo
    BuildInfo.new(commit: App::BUILD_COMMIT, build_time: App::BUILD_TIME)
  end
end
