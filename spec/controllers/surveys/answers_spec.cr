require "../../spec_helper"
require "../helpers/spec_clean_up"
require "../helpers/survey_helper"

describe Surveys::Answers do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#create" do
    it "should create answers" do
      questions = SurveyHelper.create_questions
      survey = SurveyHelper.create_survey(question_order: questions.map(&.id))

      answers = [
        {
          question_id: questions[0].id,
          survey_id:   survey.id,
          answer_text: "Green",
        },
        {
          question_id: questions[1].id,
          survey_id:   survey.id,
          answer_text: "Cat",
        },
        {
          question_id: questions[2].id,
          survey_id:   survey.id,
          answer_text: "Pizza",
        },
      ].to_json

      response = client.post(ANSWERS_BASE, headers: headers, body: answers)
      response.status_code.should eq(201)
    end

    it "should error if required questions are left out" do
      questions = SurveyHelper.create_questions
      survey = SurveyHelper.create_survey(question_order: questions.map(&.id))

      answers = [
        {
          question_id: questions[1].id,
          survey_id:   survey.id,
          answer_text: "Cat",
        },
        {
          question_id: questions[2].id,
          survey_id:   survey.id,
          answer_text: "Pizza",
        },
      ].to_json

      response = client.post(ANSWERS_BASE, headers: headers, body: answers)
      response.status_code.should eq(400)
    end

    it "should error if answers are not for the same survey" do
      questions = SurveyHelper.create_questions
      survey1 = SurveyHelper.create_survey(question_order: questions.map(&.id))
      survey2 = SurveyHelper.create_survey(question_order: questions.map(&.id))

      answers = [
        {
          question_id: questions[0].id,
          survey_id:   survey1.id,
          answer_text: "Green",
        },
        {
          question_id: questions[1].id,
          survey_id:   survey2.id,
          answer_text: "Cat",
        },
      ].to_json

      response = client.post(ANSWERS_BASE, headers: headers, body: answers)
      response.status_code.should eq(400)
    end
  end
end

ANSWERS_BASE = Surveys::Answers.base_route
