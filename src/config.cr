require "dns"
require "dns/ext/addrinfo"

# Application dependencies
require "action-controller"

require "./constants"
require "./error"
require "./controllers/application"
require "./models/*"
require "./controllers/*"
require "./logging"
require "placeos-models"

alias Tenant = PlaceOS::Model::Tenant
alias Attendee = PlaceOS::Model::Attendee
alias Guest = PlaceOS::Model::Guest
alias EventMetadata = PlaceOS::Model::EventMetadata
alias Booking = PlaceOS::Model::Booking
alias Survey = PlaceOS::Model::Survey
alias OutlookManifest = PlaceOS::Model::OutlookManifest
alias History = PlaceOS::Model::History

# Server required after application controllers
require "action-controller/server"

# Execution contexts (no-ops without -Dpreview_mt -Dexecution_context).
# The bookings index route can return large payloads, so it runs the whole
# request in a dedicated "bookings" context. Unbound routes offload their
# response serialisation to the shared response context.
ActionController::ExecutionContext.define "bookings"
ActionController::ExecutionContext.parallelism "bookings", ENV["BOOKINGS_WORKERS"]?.try(&.to_i) || 4

if (response_parallelism = ENV["OFFLOAD_WORKERS"]?.try(&.to_i)) && response_parallelism > 0
  ActionController::ExecutionContext.offload_responses
  ActionController::ExecutionContext.response_parallelism = response_parallelism
end

# Filter out sensitive params that shouldn't be logged
filter_params = ["password", "bearer_token"]
keeps_headers = ["X-Request-ID"]

# Add handlers that should run before your application
ActionController::Server.before(
  ActionController::ErrorHandler.new(App.running_in_production?, keeps_headers),
  ActionController::LogHandler.new(filter_params, ms: true)
)

# Configure session cookies
# NOTE:: Change these from defaults
ActionController::Session.configure do |settings|
  settings.key = App::COOKIE_SESSION_KEY
  settings.secret = App::COOKIE_SESSION_SECRET
  # HTTPS only:
  settings.secure = App.running_in_production?
end
