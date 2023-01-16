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
    survey_id : Int64? = nil
  ) : Array(Survey::Question::Responder)
    query = Survey::Question.query.select("id, title, description, type, options, required, choices, max_rating, tags")

    if survey_id
      question_ids = Page.find!(survey_id).question_ids
      query = query.where { id.in?(question_ids) }
    end

    query.to_a.map(&.as_json)
  end

  # creates a new question
  @[AC::Route::POST("/", body: :question_body, status_code: HTTP::Status::CREATED)]
  def create(question_body : Survey::Question::Responder) : Survey::Question::Responder
    question = question_body.to_question
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
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    question.delete
  end
end
