# Survey questions, this domain's reusable bank of questions that surveys reference by id in their pages and that answers respond to
class Surveys::Questions < Application
  include Utils::SurveyHelpers

  base "/api/staff/v1/surveys/questions"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_question(id : Int64)
    @question = find_question!(id)
  end

  getter! question : Survey::Question

  # questions are shared by the domain's surveys and have no zones, so only admins and support may change them
  @[AC::Route::Filter(:before_action, only: [:create, :update, :destroy])]
  private def confirm_edit
    raise Error::Forbidden.new("only admins and support can edit survey questions") unless is_support?
  end

  # =====================
  # Routes
  # =====================

  # List survey questions.
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(description: "only return questions referenced by this survey's pages", example: "1234")]
    survey_id : Int64? = nil,
    @[AC::Param::Info(description: "true returns only soft-deleted (superseded or retired) questions, false only active ones; omit for all", example: "false")]
    deleted : Bool? = nil,
  ) : Array(Survey::Question)
    find_survey!(survey_id) if survey_id
    Survey::Question.list(survey_id, deleted, survey_authority_id)
  end

  # Create a survey question.
  @[AC::Route::POST("/", body: :question, status_code: HTTP::Status::CREATED)]
  def create(question : Survey::Question) : Survey::Question
    question.authority_id = survey_authority_id
    question.save!
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(question.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating question data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating question data")
    end
  end

  # Update a survey question and return it; changing an answered question creates a new version with a new id.
  @[AC::Route::PUT("/:id", body: :question_body)]
  @[AC::Route::PATCH("/:id", body: :question_body)]
  def update(
    question_body : Survey::Question,
    @[AC::Param::Info(description: "when a new version is created, move the answers of the previous version to it. Defaults to false: answers stay with the version they answered", example: "true")]
    migrate_answers : Bool = false,
  ) : Survey::Question
    previous_id = question.id.as(Int64)
    PgORM::Database.transaction do
      question.patch(question_body)
      question.migrate_answers_from(previous_id) if migrate_answers && question.id != previous_id
    end
    question
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(question.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating question data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating question data")
    end
  end

  # Get a survey question.
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the numeric id of the question", example: "1234")]
    question_id : Int64,
  ) : Survey::Question
    question
  end

  # Delete a survey question.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    question.maybe_soft_delete
  end
end
