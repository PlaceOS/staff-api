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

  # the number of requests to queue before responding with too many requests
  QUEUE_LIMIT = ENV["STAFF_QUEUE_LIMIT"]?.try &.to_i
  USER_LOCK   = Hash(String, Mutex).new { |lock, user| lock[user] = Mutex.new }
  USER_COUNT  = Hash(String, Int32).new { |count, user| count[user] = 0 }
  COUNT_LOCK  = Mutex.new

  macro add_request_queue
    def request_queue : Nil
      limit = QUEUE_LIMIT
      return yield unless limit

      user_id = user_token.id

      # ensure user
      lock = COUNT_LOCK.synchronize do
        count = USER_COUNT[user_id]
        raise Error::TooManyRequests.new("user #{user_id} has over #{limit} requests occuring concurrently") if count >= limit
        USER_COUNT[user_id] = count + 1
        USER_LOCK[user_id]
      end

      begin
        lock.synchronize { yield }
      ensure
        COUNT_LOCK.synchronize do
          count = USER_COUNT[user_id] - 1
          if count.zero?
            USER_COUNT.delete user_id
            USER_LOCK.delete user_id
          else
            USER_COUNT[user_id] = count
          end
        end
      end
    end
  end

  # =========================================
  # LOGGING
  # =========================================
  Log = ::App::Log.for("controller")
  @request_id : String? = nil

  # This makes it simple to match client requests with server side logs.
  # When building microservices this ID should be propagated to upstream services.
  @[AC::Route::Filter(:before_action)]
  protected def configure_request_logging
    @request_id = request_id = UUID.random.to_s
    Log.context.set(
      client_ip: client_ip,
      request_id: request_id,
    )
    response.headers["X-Request-ID"] = request_id
  end

  # ============================
  # JWT Scope Check
  # ============================
  before_action :check_jwt_scope

  protected def check_jwt_scope
    access = user_token.get_access("public")
    block_access = true

    if request.method.downcase == "get"
      block_access = access.none?
    else
      block_access = !access.write?
    end

    if block_access
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

  protected def attending_guest(
    visitor : Attendee?,
    guest : Guest?,
    is_parent_metadata = false,
    meeting_details = nil
  ) : Guest | Attendee
    if guest
      guest.to_h(visitor, is_parent_metadata, meeting_details)
    elsif visitor
      visitor.to_h(is_parent_metadata, meeting_details)
    else
      raise "requires either an attendee or a guest"
    end
  end

  # for converting comma seperated lists
  # i.e. `"id-1,id-2,id-3"`
  struct ConvertStringArray
    def convert(raw : String)
      raw.split(',').map!(&.strip).reject(&.empty?).uniq!
    end
  end

  # =========================================
  # ERROR HANDLERS
  # =========================================

  # 429 if too many requests
  @[AC::Route::Exception(Error::TooManyRequests, status_code: HTTP::Status::TOO_MANY_REQUESTS)]
  def too_many_requests(error) : CommonError
    Log.debug { error.message }
    render_error(error)
  end

  # 400 if no bearer token
  @[AC::Route::Exception(Error::BadRequest, status_code: HTTP::Status::BAD_REQUEST)]
  def bad_request(error) : CommonError
    Log.debug { error.message }
    render_error(error)
  end

  # 401 if no bearer token
  @[AC::Route::Exception(Error::Unauthorized, status_code: HTTP::Status::UNAUTHORIZED)]
  def resource_requires_authentication(error) : CommonError
    Log.debug { error.message }
    render_error(error)
  end

  # 403 if user role invalid for a route
  @[AC::Route::Exception(Error::Forbidden, status_code: HTTP::Status::FORBIDDEN)]
  def resource_access_forbidden(error) : Nil
    Log.warn(exception: error) { "access attempt to restricted resource" }
  end

  # 404 if resource not present
  @[AC::Route::Exception(Error::NotFound, status_code: HTTP::Status::NOT_FOUND)]
  @[AC::Route::Exception(PgORM::Error::RecordNotFound, status_code: HTTP::Status::NOT_FOUND)]
  def sql_record_not_found(error) : CommonError
    Log.debug { error.message }
    render_error(error)
  end

  # 501 if request isn't implemented for the current tenent
  @[AC::Route::Exception(Error::NotImplemented, status_code: HTTP::Status::NOT_IMPLEMENTED)]
  def action_not_implemented(error) : CommonError
    Log.debug { error.message }
    render_error(error)
  end

  # provides a list of acceptable content types if an unknown one is requested
  struct ContentError
    include JSON::Serializable
    include YAML::Serializable

    getter error : String
    getter accepts : Array(String)? = nil

    def initialize(@error, @accepts = nil)
    end
  end

  # covers no acceptable response format and not an acceptable post format
  @[AC::Route::Exception(AC::Route::NotAcceptable, status_code: HTTP::Status::NOT_ACCEPTABLE)]
  @[AC::Route::Exception(AC::Route::UnsupportedMediaType, status_code: HTTP::Status::UNSUPPORTED_MEDIA_TYPE)]
  def bad_media_type(error) : ContentError
    ContentError.new error: error.message.not_nil!, accepts: error.accepts
  end

  # Provides details on which parameter is missing or invalid
  struct ParameterError
    include JSON::Serializable
    include YAML::Serializable

    getter error : String
    getter parameter : String? = nil
    getter restriction : String? = nil

    def initialize(@error, @parameter = nil, @restriction = nil)
    end
  end

  # handles paramater missing or a bad paramater value / format
  @[AC::Route::Exception(AC::Route::Param::MissingError, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
  @[AC::Route::Exception(AC::Route::Param::ValueError, status_code: HTTP::Status::BAD_REQUEST)]
  def invalid_param(error) : ParameterError
    ParameterError.new error: error.message.not_nil!, parameter: error.parameter, restriction: error.restriction
  end

  @[AC::Route::Exception(PQ::PQError, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
  def postgresql_error(error) : CommonError
    if error.message =~ App::PG_UNIQUE_CONSTRAINT_REGEX
      render_error(error)
    else
      raise error
    end
  end

  @[AC::Route::Exception(PlaceCalendar::Exception, status_code: HTTP::Status::INTERNAL_SERVER_ERROR)]
  def handled_calendar_exception(error) : CommonError
    # Adding `http_body` during dev to inspect errors from office/google clients
    render_error(error, "unexpected upstream response #{error.http_status}: #{error.message}\n#{error.http_body}")
  end

  # handler for errors in upstream requests
  # like invalid data
  @[AC::Route::Exception(Error::BadUpstreamResponse, status_code: HTTP::Status::INTERNAL_SERVER_ERROR)]
  def bad_upstream_response(error) : CommonError
    Log.debug { error.message }
    render_error(error, "bad upstream response #{error.message}")
  end

  @[AC::Route::Exception(Error::InconsistentState, status_code: HTTP::Status::INTERNAL_SERVER_ERROR)]
  def inconsistent_state(error) : CommonError
    Log.debug { error.message }
    render_error(error, "inconsistent state #{error.message}")
  end

  # handler for a few different errors
  @[AC::Route::Exception(Error::NotAllowed, status_code: HTTP::Status::METHOD_NOT_ALLOWED)]
  @[AC::Route::Exception(PgORM::Error, status_code: HTTP::Status::INTERNAL_SERVER_ERROR)]
  @[AC::Route::Exception(::PlaceOS::Client::API::Error, status_code: HTTP::Status::NOT_FOUND)]
  @[AC::Route::Exception(JSON::SerializableError, status_code: HTTP::Status::BAD_REQUEST)]
  @[AC::Route::Exception(::Enumerable::EmptyError, status_code: HTTP::Status::NOT_FOUND)] # TODO: Should be caught where it's happening, or the code refactored.
  def handled_generic_error(error) : CommonError
    render_error(error)
  end

  # generic error feedback, backtraces only provided in development
  struct CommonError
    include JSON::Serializable
    include YAML::Serializable

    getter error : String
    property backtrace : Array(String)? = nil

    def initialize(@error)
    end
  end

  protected def render_error(error, message = nil)
    Log.warn(exception: error) { error.message }
    error_resp = CommonError.new(message || error.message || error.inspect_with_backtrace)
    error_resp.backtrace = error.backtrace? unless App.running_in_production?
    error_resp
  end

  struct ValidationError
    include JSON::Serializable
    include YAML::Serializable

    getter error : String
    getter failures : Array(NamedTuple(field: String?, reason: String))

    def initialize(@error, @failures)
    end
  end

  # handles model validation errors
  @[AC::Route::Exception(Error::ModelValidation, status_code: HTTP::Status::UNPROCESSABLE_ENTITY)]
  def model_validation(error) : ValidationError
    ValidationError.new error.message.not_nil!, error.failures
  end

  # TODO: Refactor the following methods into a module

  protected def get_hosts_event(event : PlaceCalendar::Event, host : String? = nil) : PlaceCalendar::Event
    start_time = event.event_start.at_beginning_of_day
    end_time = event.event_end.not_nil!.at_end_of_day
    ical_uid = event.ical_uid.not_nil!
    host_cal = host || event.host.not_nil!
    client.list_events(host_cal, host_cal, start_time, end_time, ical_uid: ical_uid).first
  end

  protected def get_event_metadata(event : PlaceCalendar::Event, system_id : String? = nil, search_recurring : Bool = true) : EventMetadata?
    tenant = current_tenant
    query = if tenant.platform == "office365"
              EventMetadata.by_tenant(tenant.id).where(ical_uid: event.ical_uid)
            else
              EventMetadata.by_tenant(tenant.id).where(event_id: event.id)
            end

    query = query.where(system_id: system_id.as(String)) if system_id
    meta = query.first?
    return meta if meta

    if search_recurring && event.recurring_event_id.presence && event.recurring_event_id != event.id
      query = EventMetadata.by_tenant(tenant.id).by_master_ids([event.recurring_event_id])
      query = query.where(system_id: system_id.as(String)) if system_id
      query.first?
    end
  end

  protected def get_migrated_metadata(event : PlaceCalendar::Event, system_id : String) : EventMetadata?
    meta = get_event_metadata(event, system_id, search_recurring: true)

    # check if we need to migrate
    office = client.client_id == :office365
    if meta && ((office && meta.ical_uid != event.ical_uid) || (!office && meta.event_id != event.id))
      meta = EventMetadata.migrate_recurring_metadata(system_id, event, meta)
    end
    meta
  end
end
