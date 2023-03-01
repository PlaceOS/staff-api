class Survey
  class Question
    include Clear::Model
    self.table = "questions"

    column id : Int64, primary: true, presence: false
    column title : String
    column description : String?
    column type : String
    column options : JSON::Any, presence: false
    column required : Bool, presence: false
    column choices : JSON::Any, presence: false
    column max_rating : Int32?
    column tags : Array(String), presence: false
    column deleted_at : Int64?

    has_many answers : Survey::Answer, foreign_key: "answer_id"

    timestamps

    before(:save) do |m|
      question_model = m.as(Question)
      # If the question is in the database and has answers, we need to insert a new question and soft delete the old one
      if question_model.persisted? && Survey::Answer.query.where(question_id: question_model.id).count > 0
        question_model.soft_delete
        question_model.clear_persisted
      end
    end

    struct Responder
      include JSON::Serializable

      getter id : Int64?
      getter title : String? = nil
      getter description : String? = nil
      getter type : String? = nil
      getter options : JSON::Any? = nil
      getter required : Bool? = nil
      getter choices : JSON::Any? = nil
      getter max_rating : Int32? = nil
      getter tags : Array(String)? = nil
      getter deleted : Bool? = nil

      def initialize(
        @id,
        @title = nil,
        @description = nil,
        @type = nil,
        @options = nil,
        @required = nil,
        @choices = nil,
        @max_rating = nil,
        @tags = nil,
        @deleted = nil
      )
      end

      def to_question(update : Bool = false)
        question = Survey::Question.new
        {% for key in [:title, :description, :type, :required, :max_rating, :tags] %}
          question.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
        {% end %}

        {% for key in [:options, :choices] %}
          if json = {{key.id}}
            question.{{key.id}} = JSON.parse(json.to_json) unless update && json.as_h.empty?
          elsif !update
            question.{{key.id}} = JSON.parse("{}")
          end
        {% end %}

        question
      end
    end

    def as_json
      self.options = options_column.defined? ? self.options : JSON::Any.new({} of String => JSON::Any)
      self.required = required_column.defined? ? self.required : false
      self.choices = choices_column.defined? ? self.choices : JSON::Any.new({} of String => JSON::Any)
      self.tags = tags_column.defined? ? self.tags : [] of String
      self.deleted_at = deleted_at_column.defined? ? self.deleted_at : nil

      Responder.new(
        id: self.id,
        title: self.title,
        description: self.description_column.value(nil),
        type: self.type,
        options: self.options,
        required: self.required,
        choices: self.choices,
        max_rating: self.max_rating_column.value(nil),
        tags: self.tags,
        deleted: !self.deleted_at.nil?
      )
    end

    def soft_delete
      # Using Clear::SQL.raw here to avoid an infinite loop with the before(:save) hook
      Clear::SQL.execute Clear::SQL.raw("UPDATE questions SET deleted_at = :deleted_at WHERE id = :id", deleted_at: Time.local.to_unix, id: self.id)
    end

    def maybe_soft_delete
      # Check if the question has any answers or is used in any surveys
      if Survey::Answer.query.where(question_id: self.id).count > 0 || Survey.query.where(%(pages @> '[{"question_order": [?]}]'), self.id).count > 0
        soft_delete
      else
        delete
      end
    end

    def clear_persisted
      @persisted = false
      self.id_column.clear
      self.created_at_column.clear
      self.updated_at_column.clear
      self.deleted_at_column.clear
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
