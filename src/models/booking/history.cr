require "json"

class Booking
  struct History
    include JSON::Serializable

    property state : Booking::State
    property time : Int64
    property source : String?

    def initialize(@state : Booking::State, @time : Int64, @source : String? = nil)
    end

    class Converter
      def self.to_column(x) : Array(History)?
        case x
        when Nil
          nil
        when JSON::Any
          Array(History).from_json x.to_json
        when Array(History)
          x
        else
          raise "Cannot convert from #{x.class} to Array(Booking::History)"
        end
      end

      def self.to_db(x : Array(History)?)
        x.to_json
      end
    end
  end
end

Clear::Model::Converter.add_converter("Array(Booking::History)", Booking::History::Converter)
