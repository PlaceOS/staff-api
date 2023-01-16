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

  # class Page
  #   include Clear::Model
  #   self.table = "pages"

  #   column id : Int64, primary: true, presence: false
  #   column title : String
  #   column description : String?
  #   column question_order : Array(Int64)

  #   timestamps

  #   struct Responder
  #     include JSON::Serializable

  #     getter id : Int64?
  #     getter title : String? = nil
  #     getter description : String? = nil
  #     getter question_order : Array(Int64)? = nil

  #     def initialize(@id, @title = nil, @description = nil, @question_order = nil)
  #     end

  #     def to_page(update : Bool = false)
  #       page = Survey::Page.new
  #       {% for key in [:title, :description] %}
  #           page.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
  #         {% end %}

  #       if order = question_order
  #         page.question_order = order unless update && order.empty?
  #       elsif !update
  #         page.question_order = [] of Int64
  #       end

  #       page
  #     end
  #   end

  #   def as_json
  #     self.question_order = question_order_column.defined? ? self.question_order : [] of Int64

  #     Responder.new(
  #       id: self.id,
  #       title: self.title,
  #       description: self.description_column.value(nil),
  #       question_order: self.question_order,
  #     )
  #   end

  #   def validate
  #     validate_columns
  #     validate_question_order
  #   end

  #   private def validate_columns
  #     add_error("title", "must be defined") unless title_column.defined?
  #     add_error("question_order", "must be defined") unless question_order_column.defined?
  #   end

  #   private def validate_question_order
  #     if question_order_column.defined?
  #       add_error("question_order", "must not have duplicate questions") unless question_order == question_order.uniq
  #     end
  #   end
  # end
end

Clear::Model::Converter.add_converter("Array(Survey::Page)", Survey::Page::Converter)
