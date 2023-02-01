require "json"

class Tenant
  struct OutlookConfig
    include JSON::Serializable

    property app_id : String = ""
    property base_path : String?
    property app_domain : String?
    property app_resource : String?
    property source_location : String?
    property version : String?

    def clean
      config = self
      config.app_id = config.app_id.strip.downcase
      config.base_path = (c = config.base_path) && !c.blank? ? c.strip.downcase : nil
      config.app_domain = (c = config.app_domain) && !c.blank? ? c.strip.downcase : nil
      config.app_resource = (c = config.app_resource) && !c.blank? ? c.strip.downcase : nil
      config.source_location = (c = config.source_location) && !c.blank? ? c.strip.downcase : nil
      config.version = (c = config.version) && !c.blank? ? c.strip : nil
      config
    end

    def params
      {
        app_id:          @app_id,
        base_path:       @base_path,
        app_domain:      @app_domain,
        app_resource:    @app_resource,
        source_location: @source_location,
        version:         @version,
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
        x.nil? ? x.to_json : x.clean.to_json
      end
    end
  end
end

Clear::Model::Converter.add_converter("Tenant::OutlookConfig", Tenant::OutlookConfig::Converter)
