# Survey invitations, a unique token issued to an email address that invites that person to respond to a survey
class Surveys::Invitations < Application
  include Utils::SurveyHelpers

  base "/api/staff/v1/surveys/invitations"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_invitation(token : String)
    invitation = Survey::Invitation.find_by?(token: token)
    survey_id = invitation.try(&.survey_id)
    raise Error::NotFound.new("invitation not found") unless invitation && survey_id
    # another domain's invitations are not found
    @invitation_survey = find_survey!(survey_id)
    @invitation = invitation
  end

  @[AC::Route::Filter(:before_action, only: [:update, :destroy])]
  private def confirm_edit
    confirm_survey_edit!(invitation_survey.zones)
  end

  getter! invitation_survey : Survey

  getter! invitation : Survey::Invitation

  # =====================
  # Routes
  # =====================

  # Lists the invitations to this domain's surveys, optionally filtered by survey and whether they have been sent.
  # Each invitation includes its survey_id, email, token and sent flag. Any authenticated user can list invitations.
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(description: "only return invitations for this survey id", example: "1234")]
    survey_id : Int64? = nil,
    @[AC::Param::Info(description: "true returns only invitations marked as sent, false returns those not yet sent (including unset); omit for all", example: "false")]
    sent : Bool? = nil,
  ) : Array(Survey::Invitation)
    Survey::Invitation.list(survey_id, sent, survey_authority_id)
  end

  # Creates an invitation for an email address to respond to a survey.
  # survey_id and email are required; a unique token is generated automatically and returned.
  # Admins, support or managers of the survey's zones only.
  # Returns the created invitation, 403 if not permitted, 404 if the survey isn't found, or 422 if validation fails.
  @[AC::Route::POST("/", body: :invitation, status_code: HTTP::Status::CREATED)]
  def create(invitation : Survey::Invitation) : Survey::Invitation
    survey_id = invitation.survey_id
    raise AC::Route::Param::MissingError.new("survey_id is required", "survey_id", "Int64") unless survey_id
    confirm_survey_edit!(find_survey!(survey_id).zones)
    invitation.save!
  rescue ex : Error::Forbidden | Error::NotFound | AC::Route::Param::MissingError
    # access and lookup failures keep their status, they aren't validation errors
    raise ex
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(invitation.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating invitation data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating invitation data")
    end
  end

  # Updates the invitation identified by its token with the fields provided (survey_id, email, sent).
  # Typically used to mark an invitation as sent. Omitted fields are left unchanged; the token cannot be changed.
  # Admins, support or managers of the survey's zones only; moving it to another survey requires editing that survey too.
  @[AC::Route::PUT("/:token", body: :invitation_body)]
  @[AC::Route::PATCH("/:token", body: :invitation_body)]
  def update(invitation_body : Survey::Invitation) : Survey::Invitation
    if (new_survey_id = invitation_body.survey_id) && new_survey_id != invitation.survey_id
      confirm_survey_edit!(find_survey!(new_survey_id).zones)
    end
    invitation.patch(invitation_body)
  rescue ex : Error::Forbidden | Error::NotFound | AC::Route::Param::MissingError
    # access and lookup failures keep their status, they aren't validation errors
    raise ex
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(invitation.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating survey invitation data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating survey invitation data")
    end
  end

  # Returns the invitation identified by its token, including the survey_id it is for. 404 if it belongs to another domain.
  @[AC::Route::GET("/:token")]
  def show(
    @[AC::Param::Info(name: "token", description: "the unique invitation token (a ULID)", example: "01ARZ3NDEKTSV4RRFFQ69G5FAV")]
    token : String,
  ) : Survey::Invitation
    invitation
  end

  # Permanently deletes the invitation identified by its token. Admins, support or managers of the survey's zones only.
  @[AC::Route::DELETE("/:token", status_code: HTTP::Status::ACCEPTED)]
  def destroy(
    @[AC::Param::Info(name: "token", description: "the unique invitation token (a ULID)", example: "01ARZ3NDEKTSV4RRFFQ69G5FAV")]
    token : String,
  ) : Nil
    invitation.delete
  end
end
