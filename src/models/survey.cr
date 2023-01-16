require "./survey/*"

Clear.enum TriggerType, "NONE", "RESERVED", "CHECKEDIN", "CHECKEDOUT", "NOSHOW", "REJECTED", "CANCELLED", "ENDED"

class Survey
  include Clear::Model
  self.table = "surveys"

  column id : Int64, primary: true, presence: false
  column title : String
  column description : String?
  column trigger : TriggerType, presence: false
  column zone_id : String?
  # column page_order : Array(Int64)

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
    # getter page_order : Array(Int64)? = nil
    getter pages : Array(Survey::Page)? = nil

    def initialize(@id, @title = nil, @description = nil, @trigger = nil, @zone_id = nil, @pages = nil)
    end

    def to_survey(update : Bool = false)
      survey = Survey.new
      {% for key in [:title, :description, :trigger, :zone_id] %}
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
    self.pages = pages_column.defined? ? self.pages : [] of Survey::Page

    Responder.new(
      id: self.id,
      title: self.title,
      description: self.description,
      trigger: self.trigger,
      zone_id: self.zone_id,
      pages: self.pages,
    )
  end

  def validate
    validate_columns
    # validate_page_order
  end

  private def validate_columns
    add_error("title", "must be defined") unless title_column.defined?
    add_error("pages", "must be defined") unless pages_column.defined?
  end

  # private def validate_page_order
  #   if page_order_column.defined?
  #     add_error("page_order", "must not have duplicate pages") unless page_order == page_order.uniq
  #   end
  # end
end
