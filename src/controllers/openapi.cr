class OpenAPI < ActionController::Base
    base "/api/staff/v1/openapi"

    enum PathFields
      Summary
      Description
      GET
      PUT
      POST
      DELETE
      OPTIONS
      HEAD
      PATCH
    end

    AI_CHAT_PLUGIN_OPENAPI = begin
      openapi = ActionController::OpenAPI.generate_open_api_docs(
        title: "PlaceOS staff-api",
        version: App::VERSION,
        description: "A plugin that allows the user to create and manage bookings for rooms, desks and parking spots using ChatGPT."
      )

      # Current openapi doc is about 7 times larger than the maximum allowed context size, so we need to filter it down a lot
      filter = {
        Events.base_route => [PathFields::Summary, PathFields::GET],
      }

      # only include the paths that we want to expose
      # openapi[:paths].to_h.each do |path, _details|
      #   if filter[path]?
      #     openapi[:paths][path].summary = nil unless filter[path].includes? PathFields::Summary
      #     openapi[:paths][path].description = nil unless filter[path].includes? PathFields::Description
      #     openapi[:paths][path].get = nil unless filter[path].includes? PathFields::GET
      #     openapi[:paths][path].put = nil unless filter[path].includes? PathFields::PUT
      #     openapi[:paths][path].post = nil unless filter[path].includes? PathFields::POST
      #     openapi[:paths][path].delete = nil unless filter[path].includes? PathFields::DELETE
      #     openapi[:paths][path].options = nil unless filter[path].includes? PathFields::OPTIONS
      #     openapi[:paths][path].head = nil unless filter[path].includes? PathFields::HEAD
      #     openapi[:paths][path].patch = nil unless filter[path].includes? PathFields::PATCH
      #   else
      #     openapi[:paths].delete(path)
      #   end
      # end

      # TODO: only include most likely responses for each path

      # TODO: only include the components that we want to expose
      
      openapi
    end
    
    # returns the OpenAPI representation of this service in YAML format for use in AI Chat
    # https://platform.openai.com/docs/plugins/getting-started/openapi-definition
    get "/ai_chat_plugin.yaml", :openapi_yaml do
      render yaml: AI_CHAT_PLUGIN_OPENAPI.to_yaml
    end

    # returns the OpenAPI representation of this service in JSON format for use in AI Chat
    # https://platform.openai.com/docs/plugins/getting-started/openapi-definition
    get "/ai_chat_plugin.json", :openapi_json do
      render json: AI_CHAT_PLUGIN_OPENAPI.to_json
    end
  end
  