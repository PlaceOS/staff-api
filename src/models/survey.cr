require "./survey/*"

Clear.enum TriggerType, "NONE", "RESERVED", "CHECKEDIN", "CHECKEDOUT", "REJECTED", "CANCELLED"

class Survey
  include Clear::Model
  self.table = "surveys"

  column id : Int64, primary: true, presence: false
  column title : String
  column description : String?
  column trigger : TriggerType, presence: false
  column zone_id : String?
  column building_id : String?
  column pages : Array(Survey::Page) = [] of Survey::Page

  has_many answers : Survey::Answer, foreign_key: "survey_id"

  timestamps

  struct Responder
    include JSON::Serializable

    getter id : Int64?
    getter title : String? = nil
    getter description : String? = nil
    getter trigger : TriggerType? = nil
    getter zone_id : String? = nil
    getter building_id : String? = nil
    getter pages : Array(Survey::Page)? = nil

    def initialize(@id, @title = nil, @description = nil, @trigger = nil, @zone_id = nil, @building_id = nil, @pages = nil)
    end

    def to_survey(update : Bool = false)
      survey = Survey.new
      {% for key in [:title, :description, :trigger, :zone_id, :building_id] %}
        survey.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
      {% end %}

      if survey_pages = pages
        survey.pages = survey_pages unless update && survey_pages.empty?
      elsif !update
        survey.pages = [] of Survey::Page
      end

      survey
    end
  end

  def as_json
    self.description = description_column.defined? ? self.description : ""
    self.trigger = trigger_column.defined? ? self.trigger : TriggerType::NONE
    self.zone_id = zone_id_column.defined? ? self.zone_id : ""
    self.building_id = building_id_column.defined? ? self.building_id : ""
    self.pages = pages_column.defined? ? self.pages : [] of Survey::Page

    Responder.new(
      id: self.id,
      title: self.title,
      description: self.description,
      trigger: self.trigger,
      zone_id: self.zone_id,
      building_id: self.building_id,
      pages: self.pages,
    )
  end

  def validate
    validate_columns
  end

  private def validate_columns
    add_error("title", "must be defined") unless title_column.defined?
    add_error("pages", "must be defined") unless pages_column.defined?
  end

  def question_ids
    pages.flat_map(&.question_order).uniq!
  end
end
