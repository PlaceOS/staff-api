class Outlook < ActionController::Base
  base "/api/staff/v1/outlook"

  get("/manifest.xml") do
    domain_host = request.hostname.as(String)

    render :not_found, json: "Tenant not found" unless tenant = Tenant.query.find { domain == domain_host }
    render :bad_request, json: "Tenant platform must be office365" unless tenant.platform == "office365"

    manifest = OutlookManifest.new(
      app_domain: "https://#{tenant.domain}/outlook/",
      source_location: "https://#{tenant.domain}/outlook/",
      function_file_url: "https://#{tenant.domain}/outlook/function-file/function-file.html",
      taskpane_url: "https://#{tenant.domain}/outlook/",
      bookings_button_url: "https://#{tenant.domain}/outlook/upcoming"
    )

    render xml: manifest.to_xml
  end
end
