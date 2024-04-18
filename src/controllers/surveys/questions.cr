class Surveys::Questions < Application
  base "/api/staff/v1/surveys/questions"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_question(id : Int64)
    @question = Survey::Question.find(id)
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
  ) : Array(Survey::Question)
    Survey::Question.list(survey_id, deleted)
  end

  # creates a new question
  @[AC::Route::POST("/", body: :question, status_code: HTTP::Status::CREATED)]
  def create(question : Survey::Question) : Survey::Question
    question.save!
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(question.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating question data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating question data")
    end
  end

  # patches an existing question
  # This will create a new version of the question if there are any linked answers, and then soft delete the old version.
  @[AC::Route::PUT("/:id", body: :question_body)]
  @[AC::Route::PATCH("/:id", body: :question_body)]
  def update(question_body : Survey::Question) : Survey::Question
    question.patch(question_body)
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(question.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating question data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating question data")
    end
  end

  # show a question
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the question id", example: "1234")]
    question_id : Int64
  ) : Survey::Question
    question
  end

  # deletes the question
  # This will soft delete the question if there are any linked answers or if the question is in any surveys.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    question.maybe_soft_delete
  end
end
