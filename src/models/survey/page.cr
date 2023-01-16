class Survey
  class Page
    include Clear::Model
    self.table = "pages"

    column id : Int64, primary: true, presence: false
    column title : String
    column description : String?
    column question_order : Array(Int64)

    timestamps

    struct Responder
      include JSON::Serializable

      getter id : Int64?
      getter title : String? = nil
      getter description : String? = nil
      getter question_order : Array(Int64)? = nil

      def initialize(@id, @title = nil, @description = nil, @question_order = nil)
      end

      def to_page(update : Bool = false)
        page = Survey::Page.new
        {% for key in [:title, :description] %}
            page.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
          {% end %}

        if q_order = question_order
          page.question_order = q_order unless update && q_order.empty?
        elsif !update
          page.question_order = [] of Int64
        end

        page
      end
    end

    def as_json
      self.question_order = question_order_column.defined? ? self.question_order : [] of Int64

      Responder.new(
        id: self.id,
        title: self.title,
        description: self.description_column.value(nil),
        question_order: self.question_order,
      )
    end

    def validate
      validate_columns
      validate_question_order
    end

    private def validate_columns
      add_error("title", "must be defined") unless title_column.defined?
      add_error("question_order", "must be defined") unless question_order_column.defined?
    end

    private def validate_question_order
      if question_order_column.defined?
        add_error("question_order", "must not have duplicate questions") unless question_order == question_order.uniq
      end
    end
  end
end
