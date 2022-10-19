require "json"

class Tenant
  struct OutlookConfig
    include JSON::Serializable

    property app_id : String = ""
    property app_domain : String?
    property app_resource : String?
    property source_location : String?
    property function_file_url : String?
    property taskpane_url : String?
    property rooms_button_url : String?
    property desks_button_url : String?

    def params
      {
        app_id:            @app_id,
        app_domain:        @app_domain,
        app_resource:      @app_resource,
        source_location:   @source_location,
        function_file_url: @function_file_url,
        taskpane_url:      @taskpane_url,
        rooms_button_url:  @rooms_button_url,
        desks_button_url:  @desks_button_url,
      }
    end

    class Converter
      def self.to_column(x) : OutlookConfig?
        case x
        when Nil
          nil
        when JSON::PullParser
          OutlookConfig.from_json x.read_raw
        when JSON::Any
          OutlookConfig.from_json x.to_json
        when OutlookConfig
          x
        else
          raise "Cannot convert from #{x.class} to OutlookConfig"
        end
      end

      def self.to_db(x : OutlookConfig?)
        x.to_json
      end
    end
  end
end

Clear::Model::Converter.add_converter("Tenant::OutlookConfig", Tenant::OutlookConfig::Converter)
