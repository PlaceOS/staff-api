require "place_calendar"

module Utils::MultiTenant

  macro included
    before_action :determine_tenant_from_domain
  end

  @tenant : Tenant? = nil
  @client : PlaceCalendar::Client? = nil

  def tenant
    determine_tenant_from_domain unless @tenant
    @tenant.as(Tenant)
  end

  def client
    @client ||= tenant.place_calendar_client.as(PlaceCalendar::Client)
  end

  private def determine_tenant_from_domain
    authority_domain_host = request.host.as(String)
    @tenant = Tenant.query.find { domain == authority_domain_host }
    Log.context.set(domain: authority_domain_host, tenant_id: @tenant.try &.id)
  end

end
