class Outlook < ActionController::Base
  base "/api/staff/v1/outlook"

  get("/manifest.xml") do
    manifest = OutlookManifest.new(
      app_domain: "#{App::PLACE_URI}/outlook/",
      source_location: "#{App::PLACE_URI}/outlook/",
      function_file_url: "#{App::PLACE_URI}/outlook/function-file/function-file.html",
      taskpane_url: "#{App::PLACE_URI}/outlook/",
      bookings_button_url: "#{App::PLACE_URI}/outlook/upcoming"
    )

    render xml: manifest.to_xml
  end
end
