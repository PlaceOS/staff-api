require "placeos-log-backend"
require "raven"
require "raven/integrations/action-controller"

require "./constants"

# StaffAPI Logging configuration
module App::Logging
  ::Log.progname = App::NAME
  standard_sentry = Raven::LogBackend.new
  comprehensive_sentry = Raven::LogBackend.new(capture_all: true)

  # Logging configuration
  log_backend = PlaceOS::LogBackend.log_backend
  log_level = App.running_in_production? ? ::Log::Severity::Info : ::Log::Severity::Debug
  namespaces = ["action-controller.*", "#{App::NAME}.*", "place_os.*"]

  ::Log.setup do |config|
    config.bind "*", :warn, log_backend

    namespaces.each do |namespace|
      config.bind namespace, log_level, log_backend

      # Bind raven's backend
      config.bind namespace, :info, standard_sentry
      config.bind namespace, :warn, comprehensive_sentry
    end
  end
end
