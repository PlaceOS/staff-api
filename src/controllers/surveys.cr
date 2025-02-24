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
  def index(
    @[AC::Param::Info(name: "zone_id", description: "filters surveys by zone_id", example: "zone1234")]
    zone_id : String? = nil,
    @[AC::Param::Info(name: "building_id", description: "filters surveys by building_id", example: "building1234")]
    building_id : String? = nil,
  ) : Array(Survey)
    Survey.list(zone_id, building_id)
  end

  # creates a new survey
  @[AC::Route::POST("/", body: :survey, status_code: HTTP::Status::CREATED)]
  def create(survey : Survey) : Survey
    survey.save!
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(survey.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating survey data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating survey data")
    end
  end

  # patches an existing survey
  @[AC::Route::PUT("/:id", body: :survey_body)]
  @[AC::Route::PATCH("/:id", body: :survey_body)]
  def update(survey_body : Survey) : Survey
    survey.patch(survey_body)
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(survey.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating survey data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating survey data")
    end
  end

  # show a survey
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the survey id", example: "1234")]
    survey_id : Int64,
  ) : Survey
    survey
  end

  # deletes the survey
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    survey.delete
  end
end

require "./surveys/*"
