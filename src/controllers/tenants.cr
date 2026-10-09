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

  # List the tenants.
  @[AC::Route::GET("/")]
  def index : Array(Tenant::Responder)
    Tenant.select(:id, :name, :domain, :email_domain, :platform, :booking_limits, :booking_range, :delegated, :service_account, :outlook_config, :early_checkin).to_a.map(&.as_json)
  end

  # Create a tenant.
  @[AC::Route::POST("/", body: :tenant_body, status_code: HTTP::Status::CREATED)]
  def create(tenant_body : Tenant::Responder) : Tenant::Responder
    tenant = tenant_body.to_tenant
    tenant.save! rescue raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating tenant data")
    tenant.as_json
  end

  # Update a tenant with the fields in the request body and return the saved tenant.
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

  # Delete a tenant.
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    tenant.delete
  end

  alias Limits = Hash(String, Int32)

  # Get the booking limits of the current tenant.
  @[AC::Route::GET("/current_limits")]
  def current_limits : Limits
    response.headers["X-Delegated"] = (!!current_tenant.delegated).to_s
    current_tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # Get the booking limits of a tenant.
  @[AC::Route::GET("/:id/limits")]
  def show_limits : Limits
    tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # Set the booking limits of a tenant.
  @[AC::Route::POST("/:id/limits", body: :limits)]
  def update_limits(limits : Limits) : Limits
    tenant.booking_limits = JSON.parse(limits.to_json)
    raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating booking limits") if !tenant.valid?
    tenant.save!
    tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # Get the early check-in window of the current tenant.
  @[AC::Route::GET("/current_early_checkin")]
  def current_early_checkin : Int64
    response.headers["X-Delegated"] = (!!current_tenant.delegated).to_s
    current_tenant.early_checkin
  end

  # Get the early check-in window of a tenant.
  @[AC::Route::GET("/:id/early_checkin")]
  def show_early_checkin : Int64
    tenant.early_checkin
  end

  # Set the early check-in window of a tenant.
  @[AC::Route::POST("/:id/early_checkin", body: :early_checkin)]
  def update_early_checkin(early_checkin : Int64) : Int64
    tenant.early_checkin = early_checkin
    raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating early checkin limit") if !tenant.valid?
    tenant.save!
    tenant.early_checkin
  end
end
