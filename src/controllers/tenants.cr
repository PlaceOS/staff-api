# Tenants, the calendar platform configuration (office365 or google) for a domain, along with its booking limits, booking range and early check-in window
class Tenants < Application
  base "/api/staff/v1/tenants"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:current_limits, :show_limits, :current_early_checkin, :show_early_checkin])]
  private def admin_only
    raise Error::Forbidden.new unless is_admin?
  end

  @[AC::Route::Filter(:before_action, except: [:index, :create, :current_limits, :current_early_checkin])]
  private def find_tenant(id : Int64)
    @tenant = Tenant.find(id)
  end

  getter! tenant : Tenant

  # =====================
  # Routes
  # =====================

  # Lists every configured tenant (admin only).
  # Returns id, name, domain, email_domain, platform, delegated, service_account, outlook_config,
  # booking_limits, booking_range and early_checkin. Credentials are never returned.
  @[AC::Route::GET("/")]
  def index : Array(Tenant::Responder)
    Tenant.select(:id, :name, :domain, :email_domain, :platform, :booking_limits, :booking_range, :delegated, :service_account, :outlook_config, :early_checkin).to_a.map(&.as_json)
  end

  # Creates a new tenant (admin only).
  # domain and platform (office365 or google) are required; credentials is the platform's JSON config and must parse
  # for that platform (delegated or service account variant). The domain and email_domain pair must be unique.
  # Returns the created tenant (without credentials), or 422 if validation fails.
  @[AC::Route::POST("/", body: :tenant_body, status_code: HTTP::Status::CREATED)]
  def create(tenant_body : Tenant::Responder) : Tenant::Responder
    tenant = tenant_body.to_tenant
    tenant.save! rescue raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating tenant data")
    tenant.as_json
  end

  # Updates an existing tenant's configuration with the fields provided (admin only).
  # Omitted fields are left unchanged; an empty credentials or booking_limits object is ignored rather than clearing it.
  # Returns the updated tenant (without credentials), or 422 if validation fails.
  @[AC::Route::PUT("/:id", body: :tenant_body)]
  @[AC::Route::PATCH("/:id", body: :tenant_body)]
  def update(tenant_body : Tenant::Responder) : Tenant::Responder
    changes = tenant_body.to_tenant(update: true)

    {% for key in [:name, :domain, :email_domain, :platform, :delegated, :booking_limits, :service_account, :credentials, :outlook_config, :early_checkin] %}
      begin
        tenant.{{key.id}} = changes.{{key.id}} unless changes.{{key.id}}.nil?
      rescue NilAssertionError
      end
    {% end %}

    # booking_range defaults to {} on the model, so check the request body to avoid clearing it
    if range = tenant_body.booking_range
      tenant.booking_range = range
    end

    tenant.save! rescue raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating tenant data")
    tenant.as_json
  end

  # Permanently deletes a tenant (admin only).
  # Requests on its domain will no longer resolve to this tenant's configuration.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    tenant.delete
  end

  alias Limits = Hash(String, Int32)

  # Returns the booking limits of the tenant serving the current request (resolved from the Host header and the user's email domain).
  # Limits map a booking type (e.g. desk, parking) to the maximum number of concurrent bookings a user may hold.
  # Available to any user; use this rather than the :id/limits route when you don't know the tenant id.
  # The X-Delegated response header indicates whether the tenant uses delegated calendar access.
  @[AC::Route::GET("/current_limits")]
  def current_limits : Limits
    response.headers["X-Delegated"] = (!!current_tenant.delegated).to_s
    current_tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # Returns the booking limits of the specified tenant, a map of booking type to the maximum number of concurrent bookings a user may hold.
  # Use current_limits instead to get the limits for the current user's tenant without knowing its id.
  @[AC::Route::GET("/:id/limits")]
  def show_limits : Limits
    tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # Replaces the booking limits of the specified tenant (admin only).
  # The body is the complete map of booking type to maximum concurrent bookings per user, e.g. {"desk": 1, "parking": 1};
  # booking types omitted from the map are no longer limited. Returns the saved limits.
  @[AC::Route::POST("/:id/limits", body: :limits)]
  def update_limits(limits : Limits) : Limits
    tenant.booking_limits = JSON.parse(limits.to_json)
    raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating booking limits") if !tenant.valid?
    tenant.save!
    tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # Returns the early check-in window, in seconds, of the tenant serving the current request (resolved from the Host header and the user's email domain).
  # This is how long before a booking starts that it may be checked in (defaults to 3600).
  # Available to any user; use this rather than the :id/early_checkin route when you don't know the tenant id.
  # The X-Delegated response header indicates whether the tenant uses delegated calendar access.
  @[AC::Route::GET("/current_early_checkin")]
  def current_early_checkin : Int64
    response.headers["X-Delegated"] = (!!current_tenant.delegated).to_s
    current_tenant.early_checkin
  end

  # Returns the early check-in window, in seconds, of the specified tenant: how long before a booking starts that it may be checked in.
  # Use current_early_checkin instead to get the value for the current user's tenant without knowing its id.
  @[AC::Route::GET("/:id/early_checkin")]
  def show_early_checkin : Int64
    tenant.early_checkin
  end

  # Sets the early check-in window of the specified tenant (admin only).
  # The body is a number of seconds before a booking starts that it may be checked in, e.g. 3600 for one hour.
  # Returns the saved value.
  @[AC::Route::POST("/:id/early_checkin", body: :early_checkin)]
  def update_early_checkin(early_checkin : Int64) : Int64
    tenant.early_checkin = early_checkin
    raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating early checkin limit") if !tenant.valid?
    tenant.save!
    tenant.early_checkin
  end
end
