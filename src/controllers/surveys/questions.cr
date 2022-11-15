class Surveys::Questions < Application
  base "/api/staff/v1/surveys/questions"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_question(id : Int64)
    @question = Question.find!(id)
  end

  getter! question : Survey

  # =====================
  # Routes
  # =====================

  # returns a list of surveys
  @[AC::Route::GET("/")]
  def index : Array(Survey::Question::Responder)
    Survey::Question.query.select("id, title, description, type question_options").to_a.map(&.as_json)
  end

  # creates a new question
  @[AC::Route::POST("/", body: :question_body, status_code: HTTP::Status::CREATED)]
  def create(question_body : Survey::Question::Responder) : Survey::Question::Responder
    question = question_body.to_question
    raise Error::ModelValidation.new(question.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating question data") if !question.create
    question.as_json
  end

  # deletes the question
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    question.delete
  end
end
