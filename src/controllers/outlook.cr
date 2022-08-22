class Outlook < ActionController::Base
  base "/api/staff/v1/outlook"

  def index
    Clear::Migration::Manager.instance.load_existing_migrations
    render json: {
      commit:     App::BUILD_COMMIT,
      build_time: App::BUILD_TIME,
    }
  end

  get("/manifest.xml") do
    # TODO: get values from config
    manifest = OutlookManifest.new(
      app_domain: "",
      source_location: "",
      function_file_url: "",
      taskpane_url: "",
      bookings_button_url: ""
    )

    render xml: manifest
  end
end
