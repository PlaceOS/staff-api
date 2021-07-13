class Tenants < Application
  base "/api/staff/v1/tenants"

  before_action :admin_only

  def index
    render json: Tenant.query.select("id, name, domain, platform").to_a
  end

  def create
    hashed = Hash(String, String | JSON::Any).from_json(request.body.not_nil!)
    tenant = Tenant.new(hashed)
    tenant.credentials = hashed["credentials"]?.to_json

    render :bad_request, json: {errors: tenant.errors.map { |e| {column: e.column, reason: e.reason} }} if !tenant.save
    render json: tenant.as_json
  end

  def update
    tenant = Tenant.find!(params["id"].to_i64)
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

  private def admin_only
    head(:forbidden) unless is_admin?
  end
end
