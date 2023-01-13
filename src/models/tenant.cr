require "clear"
require "json"
require "placeos-models/utilities/encryption"
require "./tenant/outlook_config"

struct Office365Config
  include JSON::Serializable

  property tenant : String
  property client_id : String
  property client_secret : String
  property conference_type : String? # = PlaceCalendar::Office365::DEFAULT_CONFERENCE
  property scopes : String = PlaceCalendar::Office365::DEFAULT_SCOPE

  def params
    {
      tenant:          @tenant,
      client_id:       @client_id,
      client_secret:   @client_secret,
      conference_type: @conference_type,
      scopes:          @scopes,
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
  property conference_type : String? # = PlaceCalendar::Google::DEFAULT_CONFERENCE

  def params
    {
      issuer:          @issuer,
      signing_key:     @signing_key,
      scopes:          @scopes,
      domain:          @domain,
      sub:             @sub,
      user_agent:      @user_agent,
      conference_type: @conference_type,
    }
  end
end

struct GoogleDelegatedConfig
  include JSON::Serializable

  property domain : String
  property user_agent : String = "PlaceOS"
  property conference_type : String? = PlaceCalendar::Google::DEFAULT_CONFERENCE

  def params
    {
      domain:          @domain,
      user_agent:      @user_agent,
      conference_type: @conference_type,
    }
  end
end

struct Office365DelegatedConfig
  include JSON::Serializable

  property conference_type : String? = PlaceCalendar::Office365::DEFAULT_CONFERENCE

  def params
    {
      conference_type: @conference_type,
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
  column booking_limits : JSON::Any, presence: false
  column outlook_config : OutlookConfig?

  column delegated : Bool?
  column service_account : String?

  has_many attendees : Attendee, foreign_key: "tenant_id"
  has_many guests : Guest, foreign_key: "tenant_id"
  has_many event_metadata : EventMetadata, foreign_key: "tenant_id"

  timestamps

  before :save, :set_delegated
  before :save, :encrypt!

  struct Responder
    include JSON::Serializable

    getter id : Int64?
    getter name : String?
    getter domain : String?
    getter platform : String?
    getter delegated : Bool?
    getter service_account : String?
    getter credentials : JSON::Any? = nil
    getter booking_limits : JSON::Any? = nil
    getter outlook_config : OutlookConfig? = nil

    def initialize(@id, @name, @domain, @platform, @delegated, @service_account, @credentials = nil, @booking_limits = nil, @outlook_config = nil)
    end

    def to_tenant(update : Bool = false)
      tenant = Tenant.new
      {% for key in [:name, :domain, :platform, :delegated, :service_account, :outlook_config] %}
        tenant.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
      {% end %}

      if creds = credentials
        tenant.credentials = creds.to_json unless update && creds.as_h.empty?
      elsif !update
        tenant.credentials = "{}"
      end

      if limits = booking_limits
        tenant.booking_limits = limits unless update && limits.as_h.empty?
      end

      tenant
    end
  end

  def validate
    validate_columns
    validate_booking_limits
    validate_credentials_for_platform
  end

  def as_json
    is_delegated = delegated_column.defined? ? self.delegated : false
    limits = booking_limits_column.defined? ? self.booking_limits : JSON::Any.new({} of String => JSON::Any)
    service = service_account_column.defined? ? self.service_account : nil
    outlook_config = outlook_config_column.defined? ? self.outlook_config : nil

    Responder.new(
      id: self.id,
      name: self.name,
      domain: self.domain,
      platform: self.platform,
      service_account: service,
      delegated: is_delegated,
      booking_limits: limits,
      outlook_config: outlook_config,
    )
  end

  def valid_json?(value : String)
    true if JSON.parse(value)
  rescue JSON::ParseException
    false
  end

  private def validate_columns
    add_error("domain", "must be defined") unless domain_column.defined?
    add_error("platform", "must be defined") unless platform_column.defined?
    add_error("platform", "must be a valid platform name") unless VALID_PLATFORMS.includes?(platform)
    add_error("credentials", "must be defined") unless credentials_column.defined?
  end

  # Try parsing the JSON for the relevant platform to make sure it works
  private def validate_credentials_for_platform
    creds = decrypt_credentials
    add_error("credentials", "must be valid JSON") unless valid_json?(creds)

    if delegated
      case platform
      when "google"
        GoogleDelegatedConfig.from_json(creds)
      when "office365"
        Office365DelegatedConfig.from_json(creds)
      end
    else
      case platform
      when "google"
        GoogleConfig.from_json(creds)
      when "office365"
        Office365Config.from_json(creds)
      end
    end
  rescue e : JSON::SerializableError
    add_error("credentials", e.message.to_s)
  end

  # Try parsing the JSON for booking limits in lieu of a stronger column type
  private def validate_booking_limits
    if booking_limits_column.defined?
      Hash(String, Int32).from_json(booking_limits.to_json)
    end
  rescue e : JSON::ParseException
    add_error("booking_limits", e.message.to_s)
  end

  def place_calendar_client
    raise "not supported, using delegated credentials" if delegated

    case platform
    when "office365"
      params = Office365Config.from_json(decrypt_credentials).params
      ::PlaceCalendar::Client.new(**params)
    when "google"
      params = GoogleConfig.from_json(decrypt_credentials).params
      ::PlaceCalendar::Client.new(**params)
    end
  end

  def place_calendar_client(bearer_token : String, expires : Int64?)
    case platform
    when "office365"
      params = Office365DelegatedConfig.from_json(decrypt_credentials).params
      cal = ::PlaceCalendar::Office365.new(bearer_token, **params, delegated_access: true)
      ::PlaceCalendar::Client.new(cal)
    when "google"
      params = GoogleDelegatedConfig.from_json(decrypt_credentials).params
      auth = ::Google::TokenAuth.new(bearer_token, expires || 5.hours.from_now.to_unix)
      cal = ::PlaceCalendar::Google.new(auth, **params, delegated_access: true)
      ::PlaceCalendar::Client.new(cal)
    end
  end

  # Encryption
  ###########################################################################

  protected def encrypt(string : String)
    raise PlaceOS::Model::Error::NoParent.new if (encryption_id = self.domain).nil?

    PlaceOS::Encryption.encrypt(string, id: encryption_id, level: PlaceOS::Encryption::Level::NeverDisplay)
  end

  # Encrypts credentials
  #
  protected def encrypt_credentials
    self.credentials = encrypt(self.credentials)
  end

  # Encrypt in place
  #
  def encrypt!
    encrypt_credentials
    self
  end

  # ensure delegated column has been defined
  def set_delegated
    self.delegated = false unless delegated_column.defined?
    self
  end

  # Decrypts the tenants's credentials string
  #
  protected def decrypt_credentials
    raise PlaceOS::Model::Error::NoParent.new if (encryption_id = self.domain).nil?

    PlaceOS::Encryption.decrypt(string: self.credentials, id: encryption_id, level: PlaceOS::Encryption::Level::NeverDisplay)
  end

  def decrypt_for!(user)
    self.credentials = decrypt_for(user)
    self
  end

  # Decrypts (if user has correct privilege) and returns the credentials string
  #
  def decrypt_for(user) : String
    raise PlaceOS::Model::Error::NoParent.new unless (encryption_id = self.domain)

    PlaceOS::Encryption.decrypt_for(user: user, string: self.credentials, level: PlaceOS::Encryption::Level::NeverDisplay, id: encryption_id)
  end

  # Determine if attributes are encrypted
  #
  def is_encrypted? : Bool
    PlaceOS::Encryption.is_encrypted?(self.credentials)
  end

  # distribute load as much as possible when using service accounts
  def which_account(user_email : String, resources = [] of String) : String
    if service_acct = self.service_account.presence
      resources << service_acct
      resources.sample.downcase
    else
      user_email.downcase
    end
  end

  def using_service_account?
    !self.service_account.presence.nil?
  end
end
