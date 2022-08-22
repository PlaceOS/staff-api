class Outlook < ActionController::Base
  base "/api/staff/v1/outlook"

  get("/manifest.xml") do
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
