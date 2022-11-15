class Survey::Answer
  include Clear::Model

  column id : Int64, primary: true, presence: false
  column answer_text : String

  belongs_to question : Survey::Question
  belongs_to survey : Survey

  timestamps

  struct Responder
    include JSON::Serializable

    getter id : Int64?
    getter question_id : Int64?
    getter survey_id : Int64?
    getter answer : String? = nil

    def initialize(@id, @question_id, @survey_id, @answer_text = nil)
    end

    def to_answer(update : Bool = false)
      answer = Survey::Answer.new
      {% for key in [:question_id, :survey_id, :answer_text] %}
        answer.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
      {% end %}

      answer
    end
  end

  def as_json
    answer_text = answer_text_column.defined? ? self.answer_text : ""

    Responder.new(
      id: self.id,
      question_id: self.question_id,
      survey_id: self.survey_id,
      answer_text: self.answer_text,
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
