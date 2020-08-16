module Utils::MultiTenant

  macro included
    before_action :deterrmine_tenant_from_domain
  end

  @tenant : Tenant? = nil

  def tenant
    if @tenant.nil?
      Log.debug("Tenant not found")
      head :not_found
    else
      @tenant
    end
  end

  private def deterrmine_tenant_from_domain
    if hostname = /[^:]+/.match(request.headers["Host"])
      @tenant = Tenant.query.find { domain == hostname[0] }
      Log.context.set(domain: hostname[0], tenant_id: @tenant.try &.id)
    end
  end

end
