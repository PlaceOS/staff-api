class Outlook < ActionController::Base
  base "/api/staff/v1/outlook"

  get("/manifest.xml") do
    domain_host = request.hostname.as(String)
    render :not_found, json: "Tenant not found" unless tenant = Tenant.query.find { domain == domain_host }
    render :bad_request, json: "Tenant platform must be office365" unless tenant.platform == "office365"
    render :bad_request, json: "Outlook not configured" unless outlook_config = tenant.outlook_config
    render :bad_request, json: "Missing app_id" if outlook_config.app_id.blank?

    manifest = OutlookManifest.new(
      app_id: outlook_config.app_id,
      app_domain: outlook_config.app_domain || "https://#{tenant.domain}/outlook/",
      app_resource: outlook_config.app_resource || "api://#{tenant.domain}/#{outlook_config.app_id}",
      source_location: outlook_config.source_location || "https://#{tenant.domain}/outlook/",
      function_file_url: outlook_config.function_file_url || "https://#{tenant.domain}/outlook/function-file/function-file.html",
      taskpane_url: outlook_config.taskpane_url || "https://#{tenant.domain}/outlook/#/book/meeting",
      rooms_button_url: outlook_config.rooms_button_url || "https://#{tenant.domain}/outlook/#/upcoming",
      desks_button_url: outlook_config.desks_button_url || "https://#{tenant.domain}/outlook/#/book/desks"
    )

    render xml: manifest.to_xml
  end
end
