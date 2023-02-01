class Surveys::Invitations < Application
  base "/api/staff/v1/surveys/invitations"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_invitation(token : String)
    @invitation = Survey::Invitation.find!({token: token})
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
  ) : Array(Survey::Invitation::Responder)
    query = Survey::Invitation.query.select("id, survey_id, token, email, sent")

    # filter
    query = query.where(survey_id: survey_id) if survey_id
    query = query.where(sent: sent) if !sent.nil?

    query.to_a.map(&.as_json)
  end

  # creates a new invitation
  @[AC::Route::POST("/", body: :invitation_body, status_code: HTTP::Status::CREATED)]
  def create(invitation_body : Survey::Invitation::Responder) : Survey::Invitation::Responder
    invitation = invitation_body.to_invitation
    raise Error::ModelValidation.new(invitation.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating invitation data") if !invitation.save
    invitation.as_json
  end

  # patches an existing survey invitation
  @[AC::Route::PUT("/:token", body: :invitation_body)]
  @[AC::Route::PATCH("/:token", body: :invitation_body)]
  def update(invitation_body : Survey::Invitation::Responder) : Survey::Invitation::Responder
    changes = invitation_body.to_invitation(update: true)

    {% for key in [:survey_id, :email, :sent] %}
      begin
        invitation.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
      rescue NilAssertionError
      end
    {% end %}

    raise Error::ModelValidation.new(invitation.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating survey invitation data") if !invitation.save
    invitation.as_json
  end

  # show an invitation
  @[AC::Route::GET("/:token")]
  def show(
    @[AC::Param::Info(name: "token", description: "the invitation token", example: "ABCDEF")]
    token : String
  ) : Survey::Invitation::Responder
    invitation.as_json
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
