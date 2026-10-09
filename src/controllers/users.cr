# Users, the signed in user's PlaceOS profile. Use `staff` to look up other people in the directory
class Users < Application
  base "/api/staff/v1/users"

  # Returns the signed in user's PlaceOS profile: id, name, email, department, groups and
  # work preferences. Use it to find out who you're acting for, i.e. their email for bookings.
  # Accepts bearer tokens and API keys for the current domain, guests are refused with 403.
  @[AC::Route::GET("/current")]
  def current : ::PlaceOS::Model::User::AdminResponse
    raise Error::Forbidden.new("guests don't have a user profile") if user_token.guest_scope?
    current_user.to_admin_struct
  end
end
