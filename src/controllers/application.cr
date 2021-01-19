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
    unless user_token.scope.includes?("public")
      Log.warn { {message: "unknown scope #{user_token.scope}", action: "authorize!", host: request.host, sub: user_token.sub} }
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
        backtrace: error.backtrace?,
      })
    end
  end

  rescue_from KeyError do |error|
    raise error unless error.message.try &.includes?("param")

    respond_with(:bad_request) do
      text error.message
      json({
        error: error.message,
      })
    end
  end

  rescue_from JSON::MappingError do |error|
    respond_with(:bad_request) do
      text error.inspect_with_backtrace
      json({
        error:     error.message,
        backtrace: error.backtrace?,
      })
    end
  end

  rescue_from ::PlaceOS::Client::API::Error do |error|
    Log.debug { error.message }
    head :not_found
  end

  # Helpful during dev, see errors from office/google clients
  unless App.running_in_production?
    rescue_from PlaceCalendar::Exception do |error|
      respond_with(:internal_server_error) do
        text "#{error.http_body} \n #{error.inspect_with_backtrace}"
        json({
          error:     error.message,
          backtrace: error.backtrace?,
        })
      end
    end
  end

  protected def get_hosts_event(event : PlaceCalendar::Event) : PlaceCalendar::Event
    start_time = event.event_start.at_beginning_of_day
    end_time = event.event_end.not_nil!.at_end_of_day
    ical_uid = event.ical_uid.not_nil!
    host_cal = event.host.not_nil!
    client.list_events(host_cal, host_cal, start_time, end_time, ical_uid: ical_uid).first
  end

  protected def get_event_metadata(event : PlaceCalendar::Event, system_id : String) : EventMetadata?
    meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.id, system_id: system_id})
    if meta.nil? && event.recurring_event_id.presence && event.recurring_event_id != event.id
      EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id, system_id: system_id})
    end
  end

  protected def get_migrated_metadata(event : PlaceCalendar::Event, system_id : String) : EventMetadata?
    meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.id, system_id: system_id})
    if (meta.nil? && event.recurring_event_id.presence && event.recurring_event_id != event.id) && (original_meta = EventMetadata.query.by_tenant(tenant.id).find({event_id: event.recurring_event_id, system_id: system_id}))
      EventMetadata.migrate_recurring_metadata(system_id, event, original_meta)
    end
  end
end
