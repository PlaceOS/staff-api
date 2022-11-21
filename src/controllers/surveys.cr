class Surveys < Application
  base "/api/staff/v1/surveys"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_survey(id : Int64)
    @survey = Survey.find!(id)
  end

  getter! survey : Survey

  # =====================
  # Routes
  # =====================

  # returns a list of surveys
  @[AC::Route::GET("/")]
  def index : Array(Survey::Responder)
    Survey.query.select("id, title, description, question_order").to_a.map(&.as_json)
  end

  # creates a new survey
  @[AC::Route::POST("/", body: :survey_body, status_code: HTTP::Status::CREATED)]
  def create(survey_body : Survey::Responder) : Survey::Responder
    survey = survey_body.to_survey
    raise Error::ModelValidation.new(survey.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating survey data") if !survey.save
    survey.as_json
  end

  # patches an existing survey
  @[AC::Route::PUT("/:id", body: :survey_body)]
  @[AC::Route::PATCH("/:id", body: :survey_body)]
  def update(survey_body : Survey::Responder) : Survey::Responder
    changes = survey_body.to_survey(update: true)

    {% for key in [:title, :description, :question_order] %}
      begin
        survey.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
      rescue NilAssertionError
      end
    {% end %}

    raise Error::ModelValidation.new(survey.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating survey data") if !survey.save
    survey.as_json
  end

  # show a survey
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the survey id", example: "...")]
    survey_id : String
  ) : Survey::Responder
    survey.as_json
  end

  # deletes the survey
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    survey.delete
  end
end
