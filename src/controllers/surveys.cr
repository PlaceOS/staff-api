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
    building_id : String? = nil
  ) : Array(Survey::Responder)
    query = Survey.query.select("id, title, description, trigger, zone_id, building_id, pages")

    query = query.where(zone_id: zone_id) if zone_id
    query = query.where(building_id: building_id) if building_id

    query.to_a.map(&.as_json)
  end

  # creates a new survey
  @[AC::Route::POST("/", body: :survey_body, status_code: HTTP::Status::CREATED)]
  def create(survey_body : Survey::Responder) : Survey::Responder
    survey = survey_body.to_survey
    raise Error::ModelValidation.new(survey.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating survey data") if !survey.save!
    survey.as_json
  end

  # patches an existing survey
  @[AC::Route::PUT("/:id", body: :survey_body)]
  @[AC::Route::PATCH("/:id", body: :survey_body)]
  def update(survey_body : Survey::Responder) : Survey::Responder
    changes = survey_body.to_survey(update: true)

    {% for key in [:title, :description, :trigger, :zone_id, :building_id, :pages] %}
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
    @[AC::Param::Info(name: "id", description: "the survey id", example: "1234")]
    survey_id : Int64
  ) : Survey::Responder
    survey.as_json
  end

  # deletes the survey
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    survey.delete
  end
end

require "./surveys/*"
