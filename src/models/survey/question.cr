class Survey
  class Question
    include Clear::Model

    column id : Int64, primary: true, presence: false
    column title : String
    column description : String?
    column type : String
    column options : JSON::Any, presence: false

    has_many answers : Survey::Answer, foreign_key: "answer_id"
    # belongs_to surveys : Array(Survey)

    timestamps

    # TODO: check question is not used by a survey before deleting
    # before :delete, :ensure_not_used

    struct Responder
      include JSON::Serializable

      getter id : Int64?
      getter title : String? = nil
      getter description : String? = nil
      getter type : String? = nil
      getter options : JSON::Any? = nil

      def initialize(@id, @title = nil, @description = nil, @type = nil, @options = nil)
      end

      def to_question(update : Bool = false)
        question = Survey::Question.new
        {% for key in [:title, :description, :type] %}
        question.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
      {% end %}

        if o = options
          question.options = JSON.parse(o.to_json) unless update && o.as_h.empty?
        elsif !update
          question.options = JSON.parse("{}")
        end

        question
      end
    end

    def as_json
      self.description = description_column.defined? ? self.description : ""
      self.options = options_column.defined? ? self.options : JSON::Any.new({} of String => JSON::Any)

      Responder.new(
        id: self.id,
        title: self.title,
        description: self.description,
        type: self.question_order,
        options: self.options,
      )
    end

    def validate
      validate_columns
    end

    private def validate_columns
      add_error("title", "must be defined") unless title_column.defined?
      add_error("type", "must be defined") unless type_column.defined?
    end
  end
end
