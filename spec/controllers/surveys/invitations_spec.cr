require "../../spec_helper"
require "../helpers/spec_clean_up"
require "../helpers/survey_helper"

describe Surveys::Invitations, tags: ["survey"] do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of invitations" do
      survey = SurveyHelper.create_survey
      invitations = [
        SurveyHelper.create_invitation(survey: survey, email: "user1@spec.test", sent: false),
        SurveyHelper.create_invitation(survey: survey, email: "user2@spec.test", sent: false),
      ]

      response = client.get(INVITATIONS_BASE, headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["email"]).should eq(invitations.map(&.email))
    end

    it "should return a list of invitations for a survey" do
      survey1 = SurveyHelper.create_survey
      survey2 = SurveyHelper.create_survey
      invitations = [
        SurveyHelper.create_invitation(survey: survey1, email: "user1@spec.test", sent: false),
        SurveyHelper.create_invitation(survey: survey2, email: "user2@spec.test", sent: false),
      ]

      response = client.get("#{INVITATIONS_BASE}?survey_id=#{survey1.id}", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["id"]).should contain(invitations[0].id)
      response_json.as_a.map(&.["id"]).should_not contain(invitations[1].id)
    end

    it "should return a list of sent invitations" do
      survey = SurveyHelper.create_survey
      invitations = [
        SurveyHelper.create_invitation(survey: survey, email: "user1@spec.test", sent: true),
        SurveyHelper.create_invitation(survey: survey, email: "user2@spec.test", sent: false),
      ]

      response = client.get("#{INVITATIONS_BASE}?sent=true", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["id"]).should contain(invitations[0].id)
      response_json.as_a.map(&.["id"]).should_not contain(invitations[1].id)
    end

    it "should return a list of not sent invitations" do
      survey = SurveyHelper.create_survey
      invitations = [
        SurveyHelper.create_invitation(survey: survey, email: "user1@spec.test", sent: true),
        SurveyHelper.create_invitation(survey: survey, email: "user2@spec.test", sent: false),
      ]

      response = client.get("#{INVITATIONS_BASE}?sent=false", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["id"]).should_not contain(invitations[0].id)
      response_json.as_a.map(&.["id"]).should contain(invitations[1].id)
    end
  end
end

INVITATIONS_BASE = Surveys::Invitations.base_route
