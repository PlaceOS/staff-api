require "place_calendar"

module Utils::MultiTenant
  macro included
    before_action :determine_tenant_from_domain
  end

  getter client : PlaceCalendar::Client do
    tenant = current_tenant
    place_client = if tenant.delegated
                     # Grab a valid token from RestAPI
                     token = get_placeos_client.users.resource_token
                     tenant.place_calendar_client token.token, token.expires
                   else
                     # Use the credentials in the database
                     tenant.place_calendar_client
                   end

    place_client.as(PlaceCalendar::Client)
  end

  @tenant : Tenant? = nil

  def tenant
    current_tenant
  end

  def current_tenant
    determine_tenant_from_domain unless @tenant
    @tenant.as(Tenant)
  end

  private def determine_tenant_from_domain
    # Token and authority domains must match
    token_domain_host = user_token.domain
    authority_domain_host = request.hostname.as(String)

    unless token_domain_host == authority_domain_host
      ::Log.with_context do
        Log.context.set({token: token_domain_host, authority: authority_domain_host})
        Log.info { "domain does not match token's" }
      end
      raise Error::Unauthorized.new "domain does not match token's"
    end

    begin
      @tenant = Tenant.query.find { domain == authority_domain_host }
      Log.context.set(domain: authority_domain_host, tenant_id: @tenant.try &.id)
    rescue error
      respond_with(:not_found) do
        text "tenant lookup failed on #{authority_domain_host} with #{error.inspect_with_backtrace}"
        json({
          error:     "tenant lookup failed on #{authority_domain_host} with #{error.message}",
          backtrace: error.backtrace?,
        })
      end
    end
  end
end
