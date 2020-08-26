require "placeos"

# Helper to interact with PlaceOS API
module Utils::PlaceOSHelpers
  # Base URL of the PlaceOS instance we are interacting with
  PLACE_URI = App::PLACE_URI

  @placeos_client : PlaceOS::Client? = nil

  def get_placeos_client : PlaceOS::Client
    @plaseos_client ||= PlaceOS::Client.from_environment_user
  end
end
