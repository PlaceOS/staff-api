class Tenants < Application
  base "/api/staff/v1/tenants"

  before_action :admin_only

  def index
    render json: Tenant.query.select("id, name, domain, platform").to_a
  end

  def create
    args = JSON.parse(request.body.not_nil!)

    tenant = Tenant.new({
      name:        args["name"],
      domain:      args["domain"],
      platform:    args["platform"],
      credentials: args["credentials"].to_json,
    })

    if tenant.save
      render json: tenant.to_json
    else
      errors = tenant.errors.map do |e|
        {column: e.column, reason: e.reason}
      end

      render :bad_request, json: {errors: errors}
    end
  end

  def destroy
    Tenant.query.find! { id == params["id"] }.delete
  end

  private def admin_only
    head(:forbidden) unless is_admin?
  end
end
