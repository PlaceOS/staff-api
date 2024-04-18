class Surveys::Invitations < Application
  base "/api/staff/v1/surveys/invitations"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_invitation(token : String)
    @invitation = Survey::Invitation.find_by(token: token)
  end

  getter! invitation : Survey::Invitation

  # =====================
  # Routes
  # =====================

  # returns a list of invitations
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(description: "the survey id to get invitations for", example: "1234")]
    survey_id : Int64? = nil,
    @[AC::Param::Info(description: "filter by sent status", example: "false")]
    sent : Bool? = nil
  ) : Array(Survey::Invitation)
    Survey::Invitation.list(survey_id, sent)
  end

  # creates a new invitation
  @[AC::Route::POST("/", body: :invitation, status_code: HTTP::Status::CREATED)]
  def create(invitation : Survey::Invitation) : Survey::Invitation
    invitation.save!
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(invitation.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating invitation data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating invitation data")
    end
  end

  # patches an existing survey invitation
  @[AC::Route::PUT("/:token", body: :invitation_body)]
  @[AC::Route::PATCH("/:token", body: :invitation_body)]
  def update(invitation_body : Survey::Invitation) : Survey::Invitation
    invitation.patch(invitation_body)
  rescue ex
    if ex.is_a?(PgORM::Error::RecordInvalid)
      raise Error::ModelValidation.new(invitation.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating survey invitation data")
    else
      raise Error::ModelValidation.new([{field: nil, reason: ex.message.to_s}.as({field: String?, reason: String})], "error validating survey invitation data")
    end
  end

  # show an invitation
  @[AC::Route::GET("/:token")]
  def show(
    @[AC::Param::Info(name: "token", description: "the invitation token", example: "ABCDEF")]
    token : String
  ) : Survey::Invitation
    invitation
  end

  # deletes the invitation
  @[AC::Route::DELETE("/:token", status_code: HTTP::Status::ACCEPTED)]
  def destroy(
    @[AC::Param::Info(name: "token", description: "the invitation token", example: "ABCDEF")]
    token : String
  ) : Nil
    invitation.delete
  end
end
