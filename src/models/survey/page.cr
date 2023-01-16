class Survey
  struct Page
    include JSON::Serializable

    property title : String = ""
    property description : String? = nil
    property question_order : Array(Int64) = [] of Int64

    def initialize(@title = "", @description = nil, @question_order = [] of Int64)
    end

    class Converter
      def self.to_column(x) : Array(Page)?
        case x
        when Nil
          nil
        when JSON::PullParser
          Array(Page).from_json x.read_raw
        when JSON::Any
          Array(Page).from_json x.to_json
        when Array(Page)
          x
        else
          raise "Cannot convert from #{x.class} to Array(Survey::Page)"
        end
      end

      def self.to_db(x : Array(Page)?)
        x.to_json
      end
    end
  end
end

Clear::Model::Converter.add_converter("Array(Survey::Page)", Survey::Page::Converter)
