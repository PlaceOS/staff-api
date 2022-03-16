class Tenants < Application
  base "/api/staff/v1/tenants"

  before_action :admin_only, except: [:current_limits, :show_limits]
  getter tenant : Tenant { find_tenant }

  def index
    render json: Tenant.query.select("id, name, domain, platform, booking_limits").to_a
  end

  def create
    hashed = Hash(String, String | JSON::Any).from_json(request.body.not_nil!)
    tenant = Tenant.new(hashed)
    tenant.credentials = hashed["credentials"]?.to_json

    render :bad_request, json: {errors: tenant.errors.map { |e| {column: e.column, reason: e.reason} }} if !tenant.save
    render json: tenant.as_json
  end

  def update
    hashed = Hash(String, String | JSON::Any).from_json(request.body.not_nil!)
    changes = Tenant.new(hashed)
    changes.credentials = hashed["credentials"]?.to_json

    {% for key in [:name, :domain, :platform, :credentials] %}
      begin
        tenant.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
      rescue NilAssertionError
      end
    {% end %}

    render :bad_request, json: {errors: tenant.errors.map { |e| {column: e.column, reason: e.reason} }} if !tenant.save
    render json: tenant.as_json
  end

  put "/:id", :update_alt { update }

  def destroy
    Tenant.find!(params["id"].to_i64).delete
  end

  get "/current_limits", :current_limits do
    render json: current_tenant.booking_limits
  end

  get "/:id/limits", :show_limits do
    render json: tenant.booking_limits
  end

  post "/:id/limits", :update_limits do
    limits = JSON.parse(request.body.not_nil!)
    tenant.booking_limits = limits
    tenant.save!

    render json: tenant.booking_limits
  end

  private def admin_only
    head(:forbidden) unless is_admin?
  end

  private def find_tenant
    Tenant.find!(params["id"].to_i64)
  end
end
