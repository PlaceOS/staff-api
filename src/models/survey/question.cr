class Survey::Question
  include Clear::Model

  column id : Int64, primary: true, presence: false
  column title : String
  column description : String?
  column type : String
  column question_options : JSON::Any, presence: false

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
    getter question_options : JSON::Any? = nil

    def initialize(@id, @title = nil, @description = nil, @type = nil, @question_options = nil)
    end

    def to_question(update : Bool = false)
      question = Survey::Question.new
      {% for key in [:title, :description, :type] %}
        question.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
      {% end %}

      if options = question_options
        question.question_options = options.to_json unless update && options.as_h.empty?
      elsif !update
        question.question_options = "{}"
      end

      question
    end
  end

  def as_json
    description = description_column.defined? ? self.description : ""
    question_options = question_options_column.defined? ? self.question_options : JSON::Any.new({} of String => JSON::Any)

    Responder.new(
      id: self.id,
      title: self.title,
      description: self.description,
      type: self.question_order,
      question_options: self.question_options,
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
