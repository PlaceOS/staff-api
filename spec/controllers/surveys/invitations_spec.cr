require "../../spec_helper"
require "../helpers/spec_clean_up"
require "../helpers/survey_helper"

describe Surveys::Invitations do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest
end

Invitations_BASE = Surveys::Invitations.base_route
