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
require "./mcp"
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

# Execution contexts (the Crystal runtime default since 1.21).
# The bookings index route can return large payloads, so it runs the whole
# request in a dedicated "bookings" context.
#
# Responses of unbound routes are not offloaded: transaction-wrapped routes
# (booking and event create / update) serialise their response before the
# transaction commits, and an offloaded fiber reads on another connection that
# can't see those writes. `offload_responses` is a compile time macro, so it
# can't be toggled by an environment variable.
ActionController::ExecutionContext.define "bookings"
ActionController::ExecutionContext.parallelism "bookings", ENV["BOOKINGS_WORKERS"]?.try(&.to_i) || 4

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
