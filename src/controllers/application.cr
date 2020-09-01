require "uuid"
require "uri"
require "./utilities/*"

abstract class Application < ActionController::Base

  # TODO:: Move this to user model
  DEFAULT_TIME_ZONE = Time::Location.load(ENV["STAFF_TIME_ZONE"]? || "Australia/Sydney")

  # =========================================
  # HELPERS
  # =========================================
  include Utils::PlaceOSHelpers
  # include Utils::GoogleHelpers
  include Utils::CurrentUser
  # include Utils::Responders
  include Utils::MultiTenant

  # =========================================
  # LOGGING
  # =========================================
  Log = ::App::Log.for("controller")
  before_action :configure_request_logging
  @request_id : String? = nil

  # This makes it simple to match client requests with server side logs.
  # When building microservices this ID should be propagated to upstream services.
  def configure_request_logging
    @request_id = request_id = UUID.random.to_s
    Log.context.set(
      client_ip: client_ip,
      request_id: request_id,
      #user_id: user_token.id
    )
    response.headers["X-Request-ID"] = request_id
  end


  # =========================================
  # HELPER METHODS
  # =========================================

  # Grab the users timezone
  def get_timezone
    tz = query_params["timezone"]?
    if tz && !tz.empty?
      Time::Location.load(URI.decode(tz))
    else
      DEFAULT_TIME_ZONE
    end
  end

  def attending_guest(visitor : Attendee?, guest : Guest?)
    if guest
      guest.to_h(visitor)
    elsif visitor
      # TODO: Need to verify in guests api if this is still needed.
      # DB structure was changed where each attendee has a corresponding guest record which keeps the email
      visitor.to_h
    else
      raise "requires either an attendee or a guest"
    end
  end

  # =========================================
  # ERROR HANDLERS
  # =========================================
  # 401 if no bearer token
  rescue_from Error::Unauthorized do |error|
    Log.debug { error.message }
    head :unauthorized
  end

  # 403 if user role invalid for a route
  rescue_from Error::Forbidden do |error|
    Log.debug { error.inspect_with_backtrace }
    head :forbidden
  end

  # 404 if resource not present
  rescue_from Clear::SQL::RecordNotFoundError do |error|
    Log.debug { error.message }
    head :not_found
  end

  rescue_from Clear::SQL::Error do |error|
    Log.debug { error.inspect_with_backtrace }
    respond_with(:internal_server_error) do
      text error.inspect_with_backtrace
      json({
        error:     error.message,
        backtrace: error.backtrace?
      })
    end
  end


end
