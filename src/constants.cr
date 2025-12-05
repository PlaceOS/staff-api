require "uri"

module App
  NAME = "staff-api"
  {% begin %}
    VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  {% end %}

  ENVIRONMENT = ENV["SG_ENV"]? || "development"
  TEST        = ENVIRONMENT == "test"
  PRODUCTION  = ENVIRONMENT == "production"

  BUILD_TIME   = {{ system("date -u").stringify }}
  BUILD_COMMIT = {{ env("PLACE_COMMIT") || "DEV" }}

  DEFAULT_PORT          = (ENV["SG_SERVER_PORT"]? || 3000).to_i
  DEFAULT_HOST          = ENV["SG_SERVER_HOST"]? || "127.0.0.1"
  DEFAULT_PROCESS_COUNT = (ENV["SG_PROCESS_COUNT"]? || 1).to_i

  COOKIE_SESSION_KEY    = ENV["COOKIE_SESSION_KEY"]? || "_staff_api_"
  COOKIE_SESSION_SECRET = ENV["COOKIE_SESSION_SECRET"]? || "4f74c0b358d5bab4000dd3c75465dc2c"

  Log         = ::Log.for(NAME)
  LOG_BACKEND = ActionController.default_backend

  PLACE_URI = ENV["PLACE_URI"]?.presence || abort("PLACE_URI not in environment")

  PLACE_HOST_HEADER = ENV["PLACE_HOST_HEADER"]?.presence

  SSL_VERIFY_NONE = !!ENV["SSL_VERIFY_NONE"]?.presence.try { |var| var.downcase.in?("1", "true") }

  PG_UNIQUE_CONSTRAINT_REGEX = /duplicate key value violates unique constraint/

  class_getter? running_in_production : Bool = PRODUCTION
end
