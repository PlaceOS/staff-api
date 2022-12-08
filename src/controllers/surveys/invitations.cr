class Surveys::Invitations < Application
  base "/api/staff/v1/surveys/invitations"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:index, :create])]
  private def find_invitation(token : String)
    @invitation = Invitation.find!({token: token})
  end

  getter! invitation : Invitation

  # =====================
  # Routes
  # =====================

  # creates a new invitation
  @[AC::Route::POST("/", body: :invitation_body, status_code: HTTP::Status::CREATED)]
  def create(invitation_body : Survey::Invitation::Responder) : Survey::Invitation::Responder
    invitation = invitation_body.to_invitation
    raise Error::ModelValidation.new(invitation.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating invitation data") if !invitation.create
    invitation.as_json
  end

  # show a survey
  @[AC::Route::GET("/:token")]
  def show(
    @[AC::Param::Info(name: "token", description: "the invitation token", example: "ABCDEF")]
    token : String
  ) : Survey::Responder
    invitation.as_json
  end

  # deletes the invitation
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    invitation.delete
  end
end
