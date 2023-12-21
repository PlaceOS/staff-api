class WellKnown < ActionController::Base
  base "/.well-known"

  get("/ai-plugin.json") do
    host = "https://#{request.headers["Host"]?}"

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
        "url":  "#{host}/.well-known/openapi.yaml",
      },
      "logo_url":       "#{host}/logo.png",
      "contact_email":  "support@place.technology",
      "legal_info_url": "https://www.placeos.com/terms-of-use",
    })
  end

  get("/openapi.yaml") do
    render(yaml: {
      "openapi": "3.0.0",
      "info":    {
        "title":       "PlaceOS staff-api",
        "description": "A plugin that allows the user to create and manage bookings for rooms, desks and parking spots using ChatGPT.",
        "version":     "#{App::VERSION}",
      },
      "servers": [
        {
          "url": "#{host}",
        },
      ],
      "paths": {
        "/api/staff/v1/bookings": {
          "get": {
            "summary":    "List bookings",
            "parameters": [
              {
                "name":        "start",
                "in":          "query",
                "description": "Start date",
                "required":    false,
                "schema":      {
                  "type":   "string",
                  "format": "date-time",
                },
              },
              {
                "name":        "end",
                "in":          "query",
                "description": "End date",
                "required":    false,
                "schema":      {
                  "type":   "string",
                  "format": "date-time",
                },
              },
              {
                "name":        "limit",
                "in":          "query",
                "description": "Limit",
                "required":    false,
                "schema":      {
                  "type":   "integer",
                  "format": "int32",
                },
              },
              {
                "name":        "offset",
                "in":          "query",
                "description": "Offset",
                "required":    false,
                "schema":      {
                  "type":   "integer",
                  "format": "int32",
                },
              },
            ],
            "responses": {
              "200": {
                "description": "OK",
                "content":     {
                  "application/json": {
                    "schema": {
                      "type":  "array",
                      "items": {
                        "$ref": "#/components/schemas/Booking",
                      },
                    },
                  },
                },
              },
            },
          },
          "post": {
            "summary":     "Create booking",
            "requestBody": {
              "description": "Booking",
              "content":     {
                "application/json": {
                  "schema": {
                    "$ref": "#/components/schemas/Booking",
                  },
                },
              },
            },
            "responses": {
              "200": {
                "description": "OK",
                "content":     {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/Booking",
                    },
                  },
                },
              },
            },
          },
        },
        "/api/staff/v1/bookings/{id}": {
          "get": {
            "summary":    "Get booking",
            "parameters": [
              {
                "name":        "id",
                "in":          "path",
                "description": "Booking ID",
                "required":    true,
                "schema":      {
                  "type": "string",
                },
              },
            ],
            "responses": {
              "200": {
                "description": "OK",
                "content":     {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/Booking",
                    },
                  },
                },
              },
            },
          },
          "put": {
            "summary":    "Update booking",
            "parameters": [
              {
                "name":        "id",
                "in":          "path",
                "description": "Booking ID",
                "required":    true,
                "schema":      {
                  "type": "string",
                },
              },
            ],
            "requestBody": {
              "description": "Booking",
              "content":     {
                "application/json": {
                  "schema": {
                    "$ref": "#/components/schemas/Booking",
                  },
                },
              },
            },
            "responses": {
              "200": {
                "description": "OK",
                "content":     {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/Booking",
                    },
                  },
                },
              },
            },
          },
          "delete": {
            "summary":    "Delete booking",
            "parameters": [
              {
                "name":        "id",
                "in":          "path",
                "description": "Booking ID",
                "required":    true,
                "schema":      {
                  "type": "string",
                },
              },
            ],
            "responses": {
              "200": {
                "description": "OK",
              },
            },
          },
        },
      },
      "components": {
        "schemas": {
          "Booking": {
            "type":       "object",
            "properties": {
              "id": {
                "type": "string",
              },
              "start": {
                "type":   "string",
                "format": "date-time",
              },
              "end": {
                "type":   "string",
                "format": "date-time",
              },
              "title": {
                "type": "string",
              },
              "description": {
                "type": "string",
              },
              "location": {
                "type": "string",
              },
              "attendees": {
                "type":  "array",
                "items": {
                  "type": "string",
                },
              },
              "organizer": {
                "type": "string",
              },
              "status": {
                "type": "string",
                "enum": [
                  "tentative",
                  "confirmed",
                  "cancelled",
                ],
              },
              "created_at": {
                "type":   "string",
                "format": "date-time",
              },
              "updated_at": {
                "type":   "string",
                "format": "date-time",
              },
            },
          },
        },
      },
    })
  end
end
