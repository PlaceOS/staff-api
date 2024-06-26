require "uri"
require "placeos-models"

alias JWTBase = PlaceOS::Model::JWTBase
alias UserJWT = PlaceOS::Model::UserJWT

# Helper to grab user and authority from a request
module Utils::CurrentUser
  Log = ::App::Log.for("authorize!")

  @user_token : ::UserJWT?

  # Parses, and validates JWT if present.
  # Throws Error::MissingBearer and JWT::Error.
  def authorize!
    return if @user_token

    # check for X-API-Key use
    if token = request.headers["X-API-Key"]? || params["api-key"]? || cookies["api-key"]?.try(&.value)
      begin
        @user_token = user_token = get_placeos_client.apikeys.inspect_jwt
        return user_token
      rescue e
        Log.warn(exception: e) { "bad or unknown X-API-Key" }
        raise Error::Unauthorized.new "unknown X-API-Key"
      end
    end

    token = acquire_token

    # Request must have a bearer token
    raise Error::Unauthorized.new unless token

    begin
      @user_token = UserJWT.decode(token)
    rescue e : JWT::Error
      Log.warn(exception: e) { "bearer malformed: #{e.message}" }
      # Request bearer was malformed
      raise Error::Unauthorized.new "bearer malformed"
    end
  rescue e
    # ensure that the user token is nil if this function ever errors.
    @user_token = nil
    raise e
  end

  # Getter for user_token
  def user_token : UserJWT
    # FIXME: Remove when action-controller respects the ordering of route callbacks
    authorize! unless @user_token
    @user_token.as(UserJWT)
  end

  # Obtains user referenced by user_token id
  getter current_user : PlaceOS::Model::User { PlaceOS::Model::User.find!(user_token.id) }

  def user
    user_token.user
  end

  # Read admin status from supplied request JWT
  def check_admin
    raise Error::Forbidden.new unless is_admin?
  end

  # Read support status from supplied request JWT
  def check_support
    raise Error::Forbidden.new unless is_support?
  end

  def is_admin?
    user_token.is_admin?
  end

  def is_support?
    token = user_token
    token.is_support? || token.is_admin?
  end

  # Pull JWT from...
  # - Authorization header
  # - "bearer_token" param
  @access_token : String? = nil

  protected def acquire_token : String?
    if token = @access_token
      token
    else
      @access_token = if token = request.headers["Authorization"]?
                        token = token.lchop("Bearer ").lchop("Token ").rstrip
                        token unless token.empty?
                      elsif token = params["bearer_token"]?
                        token.strip
                      elsif token = cookies["bearer_token"]?.try(&.value)
                        token.strip
                      end
    end
  end

  def auth_token_present?
    request.headers["X-API-Key"]? ||
      params["api-key"]? ||
      cookies["api-key"]?.try(&.value) ||
      request.headers["Authorization"]? ||
      params["bearer_token"]? ||
      cookies["bearer_token"]?.try(&.value)
  end
end
