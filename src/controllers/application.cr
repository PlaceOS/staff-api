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
  include Utils::CurrentUser
  include Utils::MultiTenant

  # =========================================
  # LOGGING
  # =========================================
  Log = ::App::Log.for("controller")
  before_action :configure_request_logging
  @request_id : String? = nil

  # This makes it simple to match client requests with server side logs.
  # When building microservices this ID should be propagated to upstream services.
  protected def configure_request_logging
    @request_id = request_id = UUID.random.to_s
    Log.context.set(
      client_ip: client_ip,
      request_id: request_id,
          # user_id: user_token.id
)
    response.headers["X-Request-ID"] = request_id
  end

  # ============================
  # JWT Scope Check
  # ============================
  before_action :check_jwt_scope

  protected def check_jwt_scope
    unless user_token.public_scope?
      Log.warn { {message: "unknown scope #{user_token.scope}", action: "authorize!", host: request.hostname, id: user_token.id} }
      raise Error::Unauthorized.new "valid scope required for access"
    end
  end

  # =========================================
  # HELPER METHODS
  # =========================================

  # Grab the users timezone
  protected def get_timezone
    tz = query_params["timezone"]?
    if tz && !tz.empty?
      Time::Location.load(URI.decode(tz))
    else
      DEFAULT_TIME_ZONE
    end
  end

  protected def attending_guest(visitor : Attendee?, guest : Guest?, is_parent_metadata = false, meeting_details = nil)
    if guest
      guest.to_h(visitor, is_parent_metadata, meeting_details)
    elsif visitor
      visitor.to_h(is_parent_metadata, meeting_details)
    else
      raise "requires either an attendee or a guest"
    end
  end

  # =========================================
  # ERROR HANDLERS
  # =========================================

  # 401 if no bearer token
  @[AC::Route::Exception(Error::Unauthorized, status_code: HTTP::Status::UNAUTHORIZED)]
  def resource_requires_authentication(error) : Nil
    Log.debug { error.message }
  end

  # 403 if user role invalid for a route
  @[AC::Route::Exception(Error::Forbidden, status_code: HTTP::Status::FORBIDDEN)]
  def resource_access_forbidden(error) : Nil
    Log.debug { error.inspect_with_backtrace }
  end

  # 404 if resource not present
  @[AC::Route::Exception(Clear::SQL::RecordNotFoundError, status_code: HTTP::Status::NOT_FOUND)]
  def sql_record_not_found(error) : Nil
    Log.debug { error.message }
  end

  # 409 if clashing booking
  @[AC::Route::Exception(Error::BookingConflict, status_code: HTTP::Status::CONFLICT)]
  def booking_conflict(error)
    Log.debug { error.message }
    {
      error:    error.message,
      bookings: error.bookings,
    }
  end

  # 410 if booking limit reached
  @[AC::Route::Exception(Error::BookingLimit, status_code: HTTP::Status::GONE)]
  def booking_limit_reached(error)
    Log.debug { error.message }
    {
      error:    error.message,
      limit:    error.limit,
      bookings: error.bookings,
    }
  end

  # 501 if request isn't implemented for the current tenent
  @[AC::Route::Exception(Error::NotImplemented, status_code: HTTP::Status::NOT_IMPLEMENTED)]
  def action_not_implemented(error)
    Log.debug { error.message }
    {
      error: error.message,
    }
  end

  # handle common errors at a global level
  # this covers no acceptable response format and not an acceptable post format
  @[AC::Route::Exception(ActionController::Route::NotAcceptable, status_code: HTTP::Status::NOT_ACCEPTABLE)]
  @[AC::Route::Exception(AC::Route::UnsupportedMediaType, status_code: HTTP::Status::UNSUPPORTED_MEDIA_TYPE)]
  def bad_media_type(error)
    {
      error:   error.message,
      accepts: error.accepts,
    }
  end

  # this covers a required paramater missing and a bad paramater value / format
  @[AC::Route::Exception(AC::Route::Param::MissingError, status_code: HTTP::Status::BAD_REQUEST)]
  @[AC::Route::Exception(AC::Route::Param::ValueError, status_code: HTTP::Status::BAD_REQUEST)]
  def invalid_param(error)
    {
      error:       error.message,
      parameter:   error.parameter,
      restriction: error.restriction,
    }
  end

  @[AC::Route::Exception(PQ::PQError, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
  def postgresql_error(error)
    if error.message =~ App::PG_UNIQUE_CONSTRAINT_REGEX
      render_error(error)
    else
      raise error
    end
  end

  @[AC::Route::Exception(PlaceCalendar::Exception, status_code: HTTP::Status::INTERNAL_SERVER_ERROR)]
  def handled_calendar_exception(error)
    # Adding `http_body` during dev to inspect errors from office/google clients
    render_error(
      error,
      "#{error.http_body} \n #{error.inspect_with_backtrace}"
    )
  end

  @[AC::Route::Exception(Clear::SQL::Error, status_code: HTTP::Status::INTERNAL_SERVER_ERROR)]
  @[AC::Route::Exception(::PlaceOS::Client::API::Error, status_code: HTTP::Status::NOT_FOUND)]
  @[AC::Route::Exception(JSON::SerializableError, status_code: HTTP::Status::BAD_REQUEST)]
  @[AC::Route::Exception(::Enumerable::EmptyError, status_code: HTTP::Status::NOT_FOUND)] # TODO: Should be caught where it's happening, or the code refactored.
  def handled_generic_error(error)
    render_error(error)
  end

  protected def render_error(error, message = nil)
    Log.warn(exception: error) { error.message }
    message = error.inspect_with_backtrace if message.nil?

    if App.running_in_production?
      {error: message}
    else
      {
        error:     message,
        backtrace: error.backtrace?,
      }
    end
  end

  # TODO: Refactor the following methods into a module

  protected def get_hosts_event(event : PlaceCalendar::Event, host : String? = nil) : PlaceCalendar::Event
    start_time = event.event_start.at_beginning_of_day
    end_time = event.event_end.not_nil!.at_end_of_day
    ical_uid = event.ical_uid.not_nil!
    host_cal = host || event.host.not_nil!
    client.list_events(host_cal, host_cal, start_time, end_time, ical_uid: ical_uid).first
  end

  protected def get_event_metadata(event : PlaceCalendar::Event, system_id : String) : EventMetadata?
    meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.id, system_id: system_id})
    if meta.nil? && event.recurring_event_id.presence && event.recurring_event_id != event.id
      EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id, system_id: system_id})
    else
      meta
    end
  end

  protected def get_migrated_metadata(event : PlaceCalendar::Event, system_id : String) : EventMetadata?
    meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.id, system_id: system_id})
    if (meta.nil? && event.recurring_event_id.presence && event.recurring_event_id != event.id) && (original_meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id, system_id: system_id}))
      EventMetadata.migrate_recurring_metadata(system_id, event, original_meta)
    else
      meta
    end
  end
end
