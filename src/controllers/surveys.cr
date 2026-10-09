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

  # Lists the surveys of this domain's authority, optionally filtered by zone and/or building.
  # Each survey includes its trigger, zone_id, building_id and its pages, where each page lists question ids in display order.
  # Any authenticated user can list surveys.
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(name: "zone_id", description: "only return surveys whose zone_id matches this zone id exactly", example: "zone-1234")]
    zone_id : String? = nil,
    @[AC::Param::Info(name: "building_id", description: "only return surveys whose building_id matches this building zone id exactly", example: "zone-5678")]
    building_id : String? = nil,
  ) : Array(Survey)
    Survey.list(zone_id, building_id, survey_authority_id)
  end

  # Creates a new survey for this domain's authority.
  # title, pages and a zone_id and/or building_id are required; each page has a title, optional description and question_order (an array of question ids).
  # zone_id can be a level, area or the organisation. trigger optionally links the survey to a booking state (e.g. CHECKEDIN, CHECKEDOUT, VISITOR_CHECKEDIN), defaults to NONE:
  # a triggered survey invites people whose booking zones include the survey's zone_id and/or building_id (both must match when both are set).
  # Create the questions first, then reference their ids in the pages (they must be this domain's questions). Admins, support or managers of the survey's zones only.
  # Returns the created survey, 403 if not permitted, or 422 if validation fails.
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

  # Updates a survey with the fields provided (title, description, trigger, zone_id, building_id, pages).
  # Omitted fields are left unchanged; pages, if provided, replaces all pages. The authority can't be changed.
  # Admins, support or managers of the survey's zones only; moving it to other zones requires managing those too.
  # Returns the updated survey, 403 if not permitted, 404 if it belongs to another domain, or 422 if validation fails.
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

  # Returns a single survey of this domain's authority, including its pages and the question ids on each page.
  # Any authenticated user can view surveys. 404 if it belongs to another domain.
  @[AC::Route::GET("/:id")]
  def show(
    @[AC::Param::Info(name: "id", description: "the numeric id of the survey", example: "1234")]
    survey_id : Int64,
  ) : Survey
    survey
  end

  # Permanently deletes a survey, with its answers and invitations.
  # The questions it references are not deleted; use the questions routes to remove those.
  # Admins, support or managers of the survey's zones only, 403 otherwise.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    survey.delete
  end
end

require "./surveys/*"
