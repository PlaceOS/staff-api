class Tenants < Application
  base "/api/staff/v1/tenants"

  # =====================
  # Filters
  # =====================

  @[AC::Route::Filter(:before_action, except: [:current_limits, :show_limits])]
  private def admin_only
    raise Error::Forbidden.new unless is_admin?
  end

  @[AC::Route::Filter(:before_action, except: [:index, :create, :current_limits])]
  private def find_tenant(id : Int64)
    @tenant = Tenant.find!(id)
  end

  getter! tenant : Tenant

  # =====================
  # Routes
  # =====================

  # lists the configured tenants
  @[AC::Route::GET("/")]
  def index : Array(Tenant::Responder)
    Tenant.query.select("id, name, domain, platform, booking_limits, delegated, service_account, outlook_config").to_a.map(&.as_json)
  end

  # creates a new tenant
  @[AC::Route::POST("/", body: :tenant_body, status_code: HTTP::Status::CREATED)]
  def create(tenant_body : Tenant::Responder) : Tenant::Responder
    tenant = tenant_body.to_tenant
    raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating tenant data") if !tenant.save
    tenant.as_json
  end

  # patches an existing booking with the changes provided
  @[AC::Route::PUT("/:id", body: :tenant_body)]
  @[AC::Route::PATCH("/:id", body: :tenant_body)]
  def update(tenant_body : Tenant::Responder) : Tenant::Responder
    changes = tenant_body.to_tenant

    {% for key in [:name, :domain, :platform, :booking_limits, :service_account, :outlook_config] %}
      begin
        tenant.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
      rescue NilAssertionError
      end
    {% end %}

    raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating tenant data") if !tenant.save
    tenant.as_json
  end

  # removes the selected tenant from the system
  @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
  def destroy : Nil
    tenant.delete
  end

  alias Limits = Hash(String, Int32)

  # returns the limits for the current domain (Host header)
  @[AC::Route::GET("/current_limits")]
  def current_limits : Limits
    response.headers["X-Delegated"] = (!!current_tenant.delegated).to_s
    current_tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # returns the limits for the selected tenant
  @[AC::Route::GET("/:id/limits")]
  def show_limits : Limits
    tenant.booking_limits.as_h.transform_values(&.as_i)
  end

  # updates the limits for the tenant provided
  @[AC::Route::POST("/:id/limits", body: :limits)]
  def update_limits(limits : Limits) : Limits
    tenant.booking_limits = JSON.parse(limits.to_json)
    raise Error::ModelValidation.new(tenant.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating booking limits") if !tenant.save
    tenant.booking_limits.as_h.transform_values(&.as_i)
  end
end
