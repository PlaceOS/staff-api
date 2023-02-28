class Surveys::Questions < Application
  base "/api/staff/v1/surveys/questions"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_question(id : Int64)
    @question = Survey::Question.find!(id)
  end

  getter! question : Survey::Question

  # =====================
  # Routes
  # =====================

  # returns a list of questions
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(description: "the survey id to get questions for", example: "1234")]
    survey_id : Int64? = nil,
    @[AC::Param::Info(description: "filter by soft-deleted", example: "true")]
    deleted : Bool? = nil
  ) : Array(Survey::Question::Responder)
    query = Survey::Question.query.select("id, title, description, type, options, required, choices, max_rating, tags")

    # filter
    if survey_id
      question_ids = Survey.find!(survey_id).question_ids
      query = query.where { id.in?(question_ids) }
    end
    query = deleted ? query.where { deleted_at != nil } : query.where { deleted_at == nil } unless deleted.nil?

    query.to_a.map(&.as_json)
  end

  # creates a new question
  @[AC::Route::POST("/", body: :question_body, status_code: HTTP::Status::CREATED)]
  def create(question_body : Survey::Question::Responder) : Survey::Question::Responder
    question = question_body.to_question
    raise Error::ModelValidation.new(question.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating question data") if !question.save
    question.as_json
  end

  # patches an existing question
  # This will create a new version of the question if there are any linked answers, and then soft delete the old version.
  @[AC::Route::PUT("/:id", body: :question_body)]
  @[AC::Route::PATCH("/:id", body: :question_body)]
  def update(question_body : Survey::Question::Responder) : Survey::Question::Responder
    changes = question_body.to_question(update: true)

    {% for key in [:title, :description, :type, :options, :required, :choices, :max_rating, :tags] %}
      begin
        question.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
      rescue NilAssertionError
      end
    {% end %}

    raise Error::ModelValidation.new(question.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating question data") if !question.save
    question.as_json
  end

  # show a question
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the question id", example: "1234")]
    question_id : Int64
  ) : Survey::Question::Responder
    question.as_json
  end

  # deletes the question
  # This will soft delete the question if there are any linked answers.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    question.maybe_soft_delete
  end
end
