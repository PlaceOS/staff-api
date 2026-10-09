# Workplace surveys, a titled set of pages that order questions (from the question bank) and can be sent to people via invitations, with responses recorded as answers
class Surveys < Application
  include Utils::SurveyHelpers

  base "/api/staff/v1/surveys"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_survey(id : Int64)
    @survey = find_survey!(id)
  end

  @[AC::Route::Filter(:before_action, only: [:destroy])]
  private def confirm_edit
    confirm_survey_edit!(survey.zones)
  end

  getter! survey : Survey

  # =====================
  # Routes
  # =====================

  # List surveys.
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "zone_id", description: "only return surveys whose zone_id matches this zone id exactly", example: "zone-1234")]
    zone_id : String? = nil,
    @[AC::Param::Info(name: "building_id", description: "only return surveys whose building_id matches this building zone id exactly", example: "zone-5678")]
    building_id : String? = nil,
  ) : Array(Survey)
    Survey.list(zone_id, building_id, survey_authority_id)
  end

  # Create a survey.
  @[AC::Route::POST("/", body: :survey, status_code: HTTP::Status::CREATED)]
  def create(survey : Survey) : Survey
    survey.authority_id = survey_authority_id
    confirm_survey_edit!(survey.zones)
    confirm_questions!(survey.pages)
    survey.save!
  rescue ex : Error::Forbidden | Error::NotFound | Error::ModelValidation | AC::Route::Param::MissingError
    # access and lookup failures keep their status, they aren't validation errors
    raise ex
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(survey.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating survey data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating survey data")
    end
  end

  # Update a survey with the fields in the request body and return the saved survey.
  @[AC::Route::PUT("/:id", body: :survey_body)]
  @[AC::Route::PATCH("/:id", body: :survey_body)]
  def update(survey_body : Survey) : Survey
    confirm_survey_edit!(survey.zones)
    zone_id = survey_body.zone_id_present? ? survey_body.zone_id : survey.zone_id
    building_id = survey_body.building_id_present? ? survey_body.building_id : survey.building_id
    new_zones = [building_id.presence, zone_id.presence].compact
    confirm_survey_edit!(new_zones) unless new_zones == survey.zones
    confirm_questions!(survey_body.pages) if survey_body.pages_present?
    survey.patch(survey_body)
  rescue ex : Error::Forbidden | Error::NotFound | Error::ModelValidation | AC::Route::Param::MissingError
    # access and lookup failures keep their status, they aren't validation errors
    raise ex
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(survey.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating survey data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating survey data")
    end
  end

  # Get a survey.
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the numeric id of the survey", example: "1234")]
    survey_id : Int64,
  ) : Survey
    survey
  end

  # Delete a survey.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    survey.delete
  end
end

require "./surveys/*"
