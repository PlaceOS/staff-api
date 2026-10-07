require "placeos-models"

# Organisation reach for tenant administration (PPT-526). Mirrors the
# rest-api resolver: cluster reach for the management partner's staff,
# partner reach for a partner's staff organisation, otherwise the caller's
# own organisation, widened by live grants. Tenants are addressed by domain,
# so reach is expressed as the hostnames of the domains in reach.
module Utils::Tenancy
  Log = ::App::Log.for("tenancy")

  class_property? enforce : Bool = App::PLACE_TENANCY_ENFORCE

  record Scope, cluster : Bool, organisation_ids : Set(UUID)

  getter tenancy_scope : Scope { resolve_tenancy_scope }

  protected def resolve_tenancy_scope : Scope
    authority = ::PlaceOS::Model::Authority.find_by_domain(request.hostname.as(String))
    organisation = authority.try(&.organisation)
    if organisation.nil?
      Log.warn { {message: "domain has no organisation, caller reaches nothing", host: request.hostname, user_id: user_token.id} }
      return Scope.new(false, Set(UUID).new)
    end

    partner = organisation.partner_id.try { |id| ::PlaceOS::Model::Partner.find?(id) }
    privileged = is_support?
    return Scope.new(true, Set(UUID).new) if privileged && partner && partner.management

    ids = if privileged && partner && organisation.partner_staff
            organisation.partner_organisations.to_a.compact_map(&.id).to_set
          else
            Set{organisation.id.as(UUID)}
          end

    unless user_token.guest_scope?
      ::PlaceOS::Model::Grant.for_user(user_token.id).each do |grant|
        next unless grant.permission_flags.read? || grant.permission_flags.manage?
        case grant.scope_type
        when ::PlaceOS::Model::Grant::SCOPE_ORGANISATION
          UUID.parse?(grant.scope_id).try { |id| ids << id }
        when ::PlaceOS::Model::Grant::SCOPE_PARTNER
          if partner_id = UUID.parse?(grant.scope_id)
            ::PlaceOS::Model::Organisation.where(partner_id: partner_id).each { |org| org.id.try { |id| ids << id } }
          end
        when ::PlaceOS::Model::Grant::SCOPE_AUTHORITY
          ::PlaceOS::Model::Authority.find?(grant.scope_id).try(&.organisation_id).try { |id| ids << id }
        end
      end
    end

    Scope.new(false, ids)
  end

  @reachable_domains_resolved = false
  @reachable_domains : Array(String)? = nil

  # Hostnames of the domains in reach; nil for cluster reach
  def reachable_domains : Array(String)?
    return @reachable_domains if @reachable_domains_resolved
    @reachable_domains_resolved = true
    scope = tenancy_scope
    @reachable_domains = if scope.cluster
                           nil
                         elsif scope.organisation_ids.empty?
                           [] of String
                         else
                           list = scope.organisation_ids.to_a.map(&.to_s)
                           ::PlaceOS::Model::Authority
                             .where("organisation_id = ANY(ARRAY[#{list.join(", ") { "?" }}]::uuid[])", list)
                             .to_a.map(&.domain)
                         end
  end

  def domain_in_reach?(domain : String) : Bool
    domains = reachable_domains
    domains.nil? || domains.includes?(domain)
  end

  # 404 for a tenant on a domain outside reach, so foreign ids look unknown
  def ensure_domain_reach!(domain : String, resource : String = "tenant") : Nil
    return if domain_in_reach?(domain)
    Log.warn do
      {
        message:  Utils::Tenancy.enforce? ? "tenancy refused" : "tenancy would refuse",
        resource: resource,
        domain:   domain,
        user_id:  user_token.id,
        path:     request.path,
      }
    end
    raise Error::NotFound.new("#{resource} not found") if Utils::Tenancy.enforce?
  end

  # Keeps only the tenants whose domain is in reach; unchanged when not enforcing
  def scope_tenants(tenants : Array(Tenant)) : Array(Tenant)
    return tenants unless Utils::Tenancy.enforce?
    domains = reachable_domains
    return tenants if domains.nil?
    tenants.select { |tenant| domains.includes?(tenant.domain) }
  end
end
