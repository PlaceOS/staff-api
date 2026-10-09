# Users, the signed in user's PlaceOS profile. Use `staff` to look up other people in the directory
class Users < Application
  base "/api/staff/v1/users"

  # Get the signed in user's profile.
  @[AC::Route::GET("/current")]
  def current : ::PlaceOS::Model::User::AdminResponse
    raise Error::Forbidden.new("guests don't have a user profile") if user_token.guest_scope?
    current_user.to_admin_struct
  end
end
