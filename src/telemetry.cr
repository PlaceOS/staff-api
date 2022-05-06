require "./logging"
require "placeos-log-backend/telemetry"

module App
  PlaceOS::LogBackend.configure_opentelemetry(
    service_name: NAME,
    service_version: VERSION,
  )
end
