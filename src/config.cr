# Application dependencies
require "action-controller"
require "active-model"
require "clear"
require "./constants"
require "./logging"
require "./error"
require "./controllers/application"
require "./controllers/*"
require "./models/*"
require "./migrations/*"

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

# Ignore certificate errors for CABS
class OpenSSL::SSL::Context::Client
  def initialize(method : LibSSL::SSLMethod = Context.default_method)
    super(method)

    if ::App::SSL_VERIFY_NONE
      self.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      {% if compare_versions(LibSSL::OPENSSL_VERSION, "1.0.2") >= 0 %}
        self.default_verify_param = "ssl_server"
      {% end %}
    end
  end
end
