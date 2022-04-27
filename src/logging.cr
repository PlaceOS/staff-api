require "placeos-log-backend"
require "placeos-log-backend/telemetry"
require "raven"
require "raven/integrations/action-controller"

require "./constants"

# StaffAPI Logging configuration
module App::Logging
  ::Log.progname = App::NAME
  standard_sentry = Raven::LogBackend.new
  comprehensive_sentry = Raven::LogBackend.new(capture_all: true)

  # Configure Sentry
  Raven.configure &.async=(true)

  # Logging configuration
  log_backend = PlaceOS::LogBackend.log_backend
  log_level = App.running_in_production? ? ::Log::Severity::Info : ::Log::Severity::Debug
  namespaces = ["action-controller.*", "#{App::NAME}.*", "place_os.*"]

  builder = ::Log.builder
  builder.bind "*", log_level, log_backend
  builder.bind "raven", :warn, log_backend

  namespaces.each do |namespace|
    builder.bind namespace, log_level, log_backend

    # Bind raven's backend
    builder.bind namespace, :info, standard_sentry
    builder.bind namespace, :warn, comprehensive_sentry
  end

  ::Log.setup_from_env(
    default_level: log_level,
    builder: builder,
    backend: log_backend,
    log_level_env: "LOG_LEVEL",
  )

  PlaceOS::LogBackend.configure_opentelemetry(
    service_name: NAME,
    service_version: VERSION,
  )
end
