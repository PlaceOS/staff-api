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

  # Lists this domain's survey questions, optionally limited to those used by a survey and/or by soft-deleted status.
  # Each question includes title, description, type, options, required, choices, max_rating, tags, a deleted flag and,
  # for a new version of an answered question, the previous_question_id it replaced. Any authenticated user can list questions.
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

  # Creates a new question in the question bank.
  # title and type are required; options, choices, max_rating, tags and required (defaults to false) are optional.
  # Add the returned id to a survey page's question_order to include it in a survey. Admins and support only, 403 otherwise.
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

  # Updates a question with the fields provided; omitted fields are left unchanged. Admins and support only.
  # Changes to the title, description, options or tags are made in place. Changing the type, choices, max_rating or
  # required flag of a question that already has answers saves it as a new version instead, so existing answers keep
  # the question they were given against: the old version is soft deleted, the new one (with a new id) records it in
  # previous_question_id, and this domain's surveys are updated to use the new version. Check the returned id.
  # Set migrate_answers to also move the old version's answers to the new version.
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

  # Returns a single question of this domain, including soft-deleted questions. 404 if it belongs to another domain.
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the numeric id of the question", example: "1234")]
    question_id : Int64,
  ) : Survey::Question
    question
  end

  # Deletes a question. Admins and support only.
  # It is soft deleted (kept, with deleted_at set) if it has answers or is referenced by any survey page,
  # otherwise it is permanently removed (a newer version keeps its own id, its previous_question_id is cleared).
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    question.maybe_soft_delete
  end
end
