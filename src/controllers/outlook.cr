class Outlook < ActionController::Base
  base "/api/staff/v1/outlook"

  get("/manifest.xml") do
    render :bad_request, json: "Missing app-id" unless app_id = query_params["app-id"]?

    domain_host = request.hostname.as(String)
    render :not_found, json: "Tenant not found" unless tenant = Tenant.query.find { domain == domain_host }
    render :bad_request, json: "Tenant platform must be office365" unless tenant.platform == "office365"

    manifest = OutlookManifest.new(
      app_domain: "https://#{tenant.domain}/outlook/",
      app_id: app_id,
      app_resource: "api://#{tenant.domain}/#{app_id}",
      source_location: "https://#{tenant.domain}/outlook/",
      function_file_url: "https://#{tenant.domain}/outlook/function-file/function-file.html",
      taskpane_url: "https://#{tenant.domain}/outlook/#/book/meeting",
      rooms_button_url: "https://#{tenant.domain}/outlook/#/upcoming",
      desks_button_url: "https://#{tenant.domain}/outlook/#/book/desks"
    )

    render xml: manifest.to_xml
  end
end
