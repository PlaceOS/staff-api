module App
  NAME = "StaffAPI"
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}

  ENVIRONMENT = ENV["SG_ENV"]? || "development"
  PRODUCTION = ENVIRONMENT == "production"

  DEFAULT_PORT = (ENV["SG_SERVER_PORT"]? || 3000).to_i
  DEFAULT_HOST = ENV["SG_SERVER_HOST"]? || "127.0.0.1"
  DEFAULT_PROCESS_COUNT = (ENV["SG_PROCESS_COUNT"]? || 1).to_i

  COOKIE_SESSION_KEY    = ENV["COOKIE_SESSION_KEY"]? || "_staff_api_"
  COOKIE_SESSION_SECRET = ENV["COOKIE_SESSION_SECRET"]? || "4f74c0b358d5bab4000dd3c75465dc2c"

  Log         = ::Log.for(NAME)
  LOG_BACKEND = ActionController.default_backend

  PG_DATABASE_URL = ENV["PG_DATABASE_URL"]
  PG_CONNECTION_POOL_SIZE = 5

  def self.running_in_production?
    PRODUCTION
  end
end

