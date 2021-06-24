require "placeos-models/version"

module App
  class Root < Application
    base "/api/staff/v1"

    get "/version", :version do
      render :ok, json: PlaceOS::Model::Version.new(
        version: App::VERSION,
        build_time: App::BUILD_TIME,
        commit: App::BUILD_COMMIT,
        service: App::NAME
      )
    end
  end
end
