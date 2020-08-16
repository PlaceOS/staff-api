class Admin < Application
  base "/api/staff/v1/admin"

  get "/create_token", :create_token do
    token = UserJWT.new(
      "Staff-API App",
      Time.local,
      Time.local + 24.hours,
      "redant.staff-api.dev",
      "123",
      UserJWT::Metadata.new(
        "Toby Carvan",
        "toby@redant.com.au"
      )
    )

    render text: token.encode
  end

  get "/debug_token", :debug_token do
    render json: user_token
  end
end
