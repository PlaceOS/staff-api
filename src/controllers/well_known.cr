class WellKnown < ActionController::Base
  base "/.well-known"

  get("/ai-plugin.json") do
    host = "https://#{request.hostname.as(String)}"

    # TODO: This should be configurable from backoffice
    openai_verification_token = ENV["OPENAI_VERIFICATION_TOKEN"] || ""

    render(json: {
      "schema_version":        "v1",
      "name_for_human":        "PlaceOS",
      "name_for_model":        "placeos",
      "description_for_human": "Plugin for managing bookings for rooms, desks and parking spots, you can add, remove and view your bookings for rooms, desks and parking spots.",
      "description_for_model": "Plugin for managing bookings for rooms, desks and parking spots, you can add, remove and view your bookings for rooms, desks and parking spots.",
      "auth":                  {
        "type":                       "oauth",
        "client_url":                 "#{host}/auth/oauth/authorize",
        "scope":                      "public",
        "authorization_url":          "#{host}/auth/oauth/token",
        "authorization_content_type": "application/json",
        "verification_tokens":        {
          "openai": "#{openai_verification_token}",
        },
      },
      "api": {
        "type": "openapi",
        "url":  "#{host}/api/staff/v1/openapi/ai_chat_plugin.yaml",
      },
      "logo_url":       "#{host}/logo.png",
      "contact_email":  "support@place.technology",
      "legal_info_url": "https://www.placeos.com/terms-of-use",
    })
  end
end
