# rest-api's scope semantics, for controllers ported from it: a request needs the `public` scope
# or the controller's own scope (e.g. `asset_types`), with read access for `can_read` and write
# access for `can_write`. Replaces staff-api's public-only `check_jwt_scope` on these controllers.
module Utils::ResourceScopes
  alias Access = PlaceOS::Model::UserJWT::Scope::Access

  macro included
    skip_action :check_jwt_scope
  end

  # the scope named after the controller, i.e. `AssetTypes` -> `asset_types`
  def resource_scope : String
    self.class.name.split("::").last.underscore
  end

  protected def can_read
    confirm_scope_access!(Access::Read)
  end

  protected def can_write
    confirm_scope_access!(Access::Write)
  end

  private def confirm_scope_access!(access : Access) : Nil
    token = user_token
    return if token.get_access("public").includes?(access) || token.get_access(resource_scope).includes?(access)
    raise Error::Forbidden.new("User does not have #{access} access to #{resource_scope}")
  end
end
