module Utils::MultiTenant

  macro included
    before_action :determine_tenant_from_domain
  end

  @tenant : Tenant? = nil

  def tenant
    determine_tenant_from_domain unless @tenant
    @tenant.as(Tenant)
  end

  private def determine_tenant_from_domain
    authority_domain_host = URI.parse(request.host.as(String)).host.to_s
    @tenant = Tenant.query.find { domain == authority_domain_host }
    Log.context.set(domain: authority_domain_host, tenant_id: @tenant.try &.id)
  end

end
