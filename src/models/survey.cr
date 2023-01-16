require "./survey/*"

Clear.enum TriggerType, "NONE", "RESERVED", "CHECKEDIN", "CHECKEDOUT", "NOSHOW", "REJECTED", "CANCELLED", "ENDED"

class Survey
  include Clear::Model
  self.table = "surveys"

  column id : Int64, primary: true, presence: false
  column title : String
  column description : String?
  column question_order : Array(Int64)
  column trigger : TriggerType, presence: false
  column zone_id : String?

  # has_many pages : Survey::Page, foreign_key: "survey_id"
  # has_many answers : Survey::Answer, foreign_key: "survey_id"

  timestamps

  struct Responder
    include JSON::Serializable

    getter id : Int64?
    getter title : String? = nil
    getter description : String? = nil
    getter question_order : Array(Int64)? = nil
    getter trigger : TriggerType? = nil
    getter zone_id : String? = nil

    def initialize(@id, @title = nil, @description = nil, @question_order = nil, @trigger = nil, @zone_id = nil)
    end

    def to_survey(update : Bool = false)
      survey = Survey.new
      {% for key in [:title, :description, :trigger, :zone_id] %}
        survey.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
      {% end %}

      if q_order = question_order
        survey.question_order = q_order unless update && q_order.empty?
      elsif !update
        survey.question_order = [] of Int64
      end

      survey
    end
  end

  def as_json
    self.description = description_column.defined? ? self.description : ""
    self.question_order = question_order_column.defined? ? self.question_order : [] of Int64
    self.trigger = trigger_column.defined? ? self.trigger : TriggerType::NONE
    self.zone_id = zone_id_column.defined? ? self.zone_id : ""

    Responder.new(
      id: self.id,
      title: self.title,
      description: self.description,
      question_order: self.question_order,
      trigger: self.trigger,
      zone_id: self.zone_id,
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
