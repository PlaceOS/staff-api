class Survey
  class Answer
    include Clear::Model
    self.table = "answers"

    column id : Int64, primary: true, presence: false
    column answer_text : String
    column answer_json : JSON::Any, presence: false

    belongs_to question : Survey::Question
    belongs_to survey : Survey

    timestamps

    struct Responder
      include JSON::Serializable

      getter id : Int64?
      getter question_id : Int64?
      getter survey_id : Int64?
      getter answer_text : String? = nil
      getter answer_json : JSON::Any? = nil

      def initialize(@id, @question_id, @survey_id, @answer_text = nil, @answer_json = nil)
      end

      def to_answer(update : Bool = false)
        answer = Survey::Answer.new
        {% for key in [:question_id, :survey_id, :answer_text] %}
          answer.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
        {% end %}

        if json = answer_json
          answer.answer_json = JSON.parse(json.to_json) unless update && json.as_h.empty?
        elsif !update
          answer.answer_json = JSON.parse("{}")
        end

        answer
      end
    end

    def as_json
      answer_text = answer_text_column.defined? ? self.answer_text : ""
      self.answer_json = answer_json_column.defined? ? self.answer_json : JSON::Any.new({} of String => JSON::Any)

      Responder.new(
        id: self.id,
        question_id: self.question_id,
        survey_id: self.survey_id,
        answer_text: self.answer_text,
        answer_json: self.answer_json,
      )
    end

    def validate
      validate_columns
    end

    private def validate_columns
      add_error("question_id", "must be defined") unless question_id_column.defined?
      add_error("survey_id", "must be defined") unless survey_id_column.defined?
      add_error("answer_text", "must be defined") unless answer_text_column.defined?
    end
  end
end
