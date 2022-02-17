require "clear"
require "json"
require "placeos-models/utilities/encryption"

struct Office365Config
  include JSON::Serializable

  property tenant : String
  property client_id : String
  property client_secret : String
  property conference_type : String? = PlaceCalendar::Office365::DEFAULT_CONFERENCE
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
  property conference_type : String? = PlaceCalendar::Google::DEFAULT_CONFERENCE

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

class Tenant
  include Clear::Model

  VALID_PLATFORMS = ["office365", "google"]

  column id : Int64, primary: true, presence: false
  column name : String?
  column domain : String
  column platform : String
  column credentials : String
  column booking_limits : JSON::Any, presence: false

  has_many attendees : Attendee, foreign_key: "tenant_id"
  has_many guests : Guest, foreign_key: "tenant_id"
  has_many event_metadata : EventMetadata, foreign_key: "tenant_id"

  before :save, :encrypt!

  def validate
    validate_columns
    validate_booking_limits
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
    case platform
    when "google"
      GoogleConfig.from_json(creds)
    when "office365"
      Office365Config.from_json(creds)
    end
  rescue e : JSON::MappingError | JSON::SerializableError
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
    case platform
    when "office365"
      params = Office365Config.from_json(decrypt_credentials).params
      ::PlaceCalendar::Client.new(**params)
    when "google"
      params = GoogleConfig.from_json(decrypt_credentials).params
      ::PlaceCalendar::Client.new(**params)
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
end
