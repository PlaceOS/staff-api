require "../../spec_helper"
require "../helpers/survey_helper"

# Surveys belong to the authority of the request's domain. Authenticated users can view surveys
# and submit answers, admins and support can edit everything and other users must manage one of
# the survey's zones (zone-perm-org grants manage to the concierge group, see Mock::Token.org_zone)
describe "Survey authority scoping and permissions", tags: ["survey"] do
  Spec.before_each do
    Survey::Invitation.truncate
    Survey.truncate
  end

  client = AC::SpecHelper.client
  admin = Mock::Headers.office365_guest
  manager = Mock::Headers.office365_normal_user(email: "survey-manager@example.com", groups: ["concierge"])
  user = Mock::Headers.office365_normal_user(email: "survey-user@example.com")

  surveys_base = Surveys.base_route
  invitations_base = Surveys::Invitations.base_route
  answers_base = Surveys::Answers.base_route
  questions_base = Surveys::Questions.base_route
  managed_zone = "zone-perm-org"

  other_authority = -> { PlaceOS::Model::Generator.authority(domain: "survey-other-#{Random::Secure.hex(4)}.dev").save!.id.as(String) }

  describe "authority" do
    it "sets the domain's authority on create, ignoring any provided" do
      body = JSON.parse(SurveyHelper.survey_responder.to_json).as_h
      body["authority_id"] = JSON::Any.new(other_authority.call)

      response = client.post(surveys_base, headers: admin, body: body.to_json)
      response.status_code.should eq(201)
      JSON.parse(response.body)["authority_id"].should eq(SurveyHelper.authority_id)
    end

    it "hides another domain's surveys" do
      mine = SurveyHelper.create_survey
      theirs = SurveyHelper.create_survey(authority_id: other_authority.call)

      ids = JSON.parse(client.get(surveys_base, headers: admin).body).as_a.map(&.["id"])
      ids.should contain(mine.id)
      ids.should_not contain(theirs.id)

      client.get("#{surveys_base}/#{theirs.id}", headers: admin).status_code.should eq(404)
      client.put("#{surveys_base}/#{theirs.id}", headers: admin, body: {title: "taken"}.to_json).status_code.should eq(404)
      client.delete("#{surveys_base}/#{theirs.id}", headers: admin).status_code.should eq(404)
      Survey.find!(theirs.id).title.should eq("New Survey")
    end

    it "adopts surveys created before they had an authority" do
      survey = SurveyHelper.create_survey
      Survey.where(id: survey.id).update_all(authority_id: nil)

      client.get("#{surveys_base}/#{survey.id}", headers: admin).status_code.should eq(200)
      Survey.find!(survey.id).authority_id.should eq(SurveyHelper.authority_id)
    end

    it "lists only the invitations and answers of the domain's surveys" do
      mine = SurveyHelper.create_invitation(SurveyHelper.create_survey)
      theirs = SurveyHelper.create_invitation(SurveyHelper.create_survey(authority_id: other_authority.call))
      ids = JSON.parse(client.get(invitations_base, headers: admin).body).as_a.map(&.["id"])
      ids.should contain(mine.id)
      ids.should_not contain(theirs.id)

      questions = SurveyHelper.create_questions
      other_survey = SurveyHelper.create_survey(question_order: questions.map(&.id), authority_id: other_authority.call)
      SurveyHelper.create_answers(other_survey, questions)
      JSON.parse(client.get(answers_base, headers: admin).body).as_a.should be_empty
    end
  end

  describe "permissions" do
    it "lets any user view surveys but not edit them" do
      survey = SurveyHelper.create_survey(zone_id: managed_zone)

      client.get(surveys_base, headers: user).status_code.should eq(200)
      client.get("#{surveys_base}/#{survey.id}", headers: user).status_code.should eq(200)
      client.post(surveys_base, headers: user, body: SurveyHelper.survey_responder(zone_id: managed_zone).to_json).status_code.should eq(403)
      client.put("#{surveys_base}/#{survey.id}", headers: user, body: {title: "nope"}.to_json).status_code.should eq(403)
      client.delete("#{surveys_base}/#{survey.id}", headers: user).status_code.should eq(403)
      Survey.find!(survey.id).title.should eq("New Survey")
    end

    it "lets zone managers edit surveys in the zones they manage" do
      response = client.post(surveys_base, headers: manager, body: SurveyHelper.survey_responder(zone_id: managed_zone).to_json)
      response.status_code.should eq(201)
      id = JSON.parse(response.body)["id"]

      client.put("#{surveys_base}/#{id}", headers: manager, body: {title: "Managed"}.to_json).status_code.should eq(200)
      client.delete("#{surveys_base}/#{id}", headers: manager).status_code.should eq(202)
    end

    it "stops zone managers editing, or moving surveys into, zones they don't manage" do
      unmanaged = SurveyHelper.create_survey(zone_id: SurveyHelper.zone)
      client.put("#{surveys_base}/#{unmanaged.id}", headers: manager, body: {title: "nope"}.to_json).status_code.should eq(403)

      managed = SurveyHelper.create_survey(zone_id: managed_zone)
      client.put("#{surveys_base}/#{managed.id}", headers: manager, body: {zone_id: SurveyHelper.zone}.to_json).status_code.should eq(403)
      Survey.find!(managed.id).zone_id.should eq(managed_zone)
    end

    it "requires a zone_id or building_id" do
      body = JSON.parse(SurveyHelper.survey_responder.to_json).as_h
      body["zone_id"] = JSON::Any.new(nil)
      body["building_id"] = JSON::Any.new("")

      client.post(surveys_base, headers: admin, body: body.to_json).status_code.should eq(422)
    end

    it "lets any user submit answers, only to the domain's surveys" do
      questions = SurveyHelper.create_questions
      survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
      answers = SurveyHelper.answer_responders(survey, questions).to_json
      client.post(answers_base, headers: user, body: answers).status_code.should eq(201)

      other_survey = SurveyHelper.create_survey(question_order: questions.map(&.id), authority_id: other_authority.call)
      other_answers = SurveyHelper.answer_responders(other_survey, questions).to_json
      client.post(answers_base, headers: user, body: other_answers).status_code.should eq(404)
    end

    it "limits invitations to users who can edit the survey" do
      managed = SurveyHelper.create_survey(zone_id: managed_zone)
      body = {survey_id: managed.id, email: "invitee@example.com"}.to_json

      client.post(invitations_base, headers: user, body: body).status_code.should eq(403)
      response = client.post(invitations_base, headers: manager, body: body)
      response.status_code.should eq(201)
      token = JSON.parse(response.body)["token"]

      client.get("#{invitations_base}/#{token}", headers: user).status_code.should eq(200)
      client.delete("#{invitations_base}/#{token}", headers: user).status_code.should eq(403)
      client.delete("#{invitations_base}/#{token}", headers: manager).status_code.should eq(202)
    end

    it "limits changes to the shared question bank to admins and support" do
      question = SurveyHelper.question_responders.first.to_json

      client.post(questions_base, headers: user, body: question).status_code.should eq(403)
      client.post(questions_base, headers: manager, body: question).status_code.should eq(403)
      client.post(questions_base, headers: admin, body: question).status_code.should eq(201)
      client.get(questions_base, headers: user).status_code.should eq(200)
    end
  end
end
