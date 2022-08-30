require "./logging"

# Application dependencies
require "action-controller"
require "auto_initialize"
require "active-model"
require "clear"

require "./constants"
require "./error"
require "./controllers/application"
require "./models/*"
require "./migrations/*"
require "./controllers/*"

# Add telemetry after application code
require "./telemetry"

# Configure Clear ORM
Clear::SQL.init(App::PG_DATABASE_URL)
Clear::Migration::Manager.instance.apply_all

# Server required after application controllers
require "action-controller/server"

# Filter out sensitive params that shouldn't be logged
filter_params = ["password", "bearer_token"]
keeps_headers = ["X-Request-ID"]

# Add handlers that should run before your application
ActionController::Server.before(
  ActionController::ErrorHandler.new(App.running_in_production?, keeps_headers),
  ActionController::LogHandler.new(filter_params)
)

# Configure session cookies
# NOTE:: Change these from defaults
ActionController::Session.configure do |settings|
  settings.key = App::COOKIE_SESSION_KEY
  settings.secret = App::COOKIE_SESSION_SECRET
  # HTTPS only:
  settings.secure = App.running_in_production?
end
