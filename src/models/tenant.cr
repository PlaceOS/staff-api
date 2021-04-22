require "clear"
require "json"

struct Office365Config
  include JSON::Serializable

  property tenant : String
  property client_id : String
  property client_secret : String

  def params
    {
      tenant:        @tenant,
      client_id:     @client_id,
      client_secret: @client_secret,
    }
  end
end

struct GoogleConfig
  include JSON::Serializable

  property issuer : String
  property signing_key : String
  property scopes : String | Array(String)
  property domain : String
  property sub : String = ""
  property user_agent : String = "PlaceOS"

  def params
    {
      issuer:      @issuer,
      signing_key: @signing_key,
      scopes:      @scopes,
      domain:      @domain,
      sub:         @sub,
      user_agent:  @user_agent,
    }
  end
end

class Tenant
  include Clear::Model

  VALID_PLATFORMS = ["office365", "google"]

  column id : Int64, primary: true, presence: false
  column name : String?
  column domain : String
  column platform : String
  column credentials : String

  has_many attendees : Attendee, foreign_key: "tenant_id"
  has_many guests : Guest, foreign_key: "tenant_id"
  has_many event_metadata : EventMetadata, foreign_key: "tenant_id"

  def validate
    add_error("domain", "must be defined") unless domain_column.defined?
    add_error("platform", "must be defined") unless platform_column.defined?
    add_error("credentials", "must be defined") unless credentials_column.defined?

    add_error("platform", "must be a valid platform name") unless VALID_PLATFORMS.includes?(platform)
    add_error("credentials", "must be valid JSON") unless valid_json?(credentials)
    validate_domain_uniqueness
    validate_credentials_for_platform
  end

  def as_json
    {
      id:       self.id,
      name:     self.name,
      domain:   self.domain,
      platform: self.platform,
    }
  end

  def valid_json?(value : String)
    true if JSON.parse(value)
  rescue JSON::ParseException
    false
  end

  private def validate_domain_uniqueness
    if Tenant.query.find { raw("domain = '#{self.domain}'") }
      add_error("domain", "duplicate error. A tenant with this domain already exists")
    end
  end

  # Try parsing the JSON for the relevant platform to make sure it works
  private def validate_credentials_for_platform
    case platform
    when "google"
      GoogleConfig.from_json(credentials)
    when "office365"
      Office365Config.from_json(credentials)
    end
  rescue e : JSON::MappingError
    add_error("credentials", e.message.to_s)
  end

  def place_calendar_client
    case platform
    when "office365"
      params = Office365Config.from_json(credentials).params
      ::PlaceCalendar::Client.new(**params)
    when "google"
      params = GoogleConfig.from_json(credentials).params
      ::PlaceCalendar::Client.new(**params)
    end
  end
end
