require "../../spec_helper"
require "../helpers/survey_helper"

describe Surveys::Answers, tags: ["survey"] do
  Spec.before_each { Survey::Answer.truncate }

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of answers" do
      answers = SurveyHelper.create_answers

      response = client.get(ANSWERS_BASE, headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["id"].as_i).sort!.should eq(answers.map(&.id.not_nil!).sort!)
    end

    it "should return a list of answers for a survey" do
      questions1 = SurveyHelper.create_questions
      survey1 = SurveyHelper.create_survey(question_order: questions1.map(&.id))
      answers1 = SurveyHelper.create_answers(survey: survey1, questions: questions1)

      questions2 = SurveyHelper.create_questions
      survey2 = SurveyHelper.create_survey(question_order: questions2.map(&.id))
      answers2 = SurveyHelper.create_answers(survey: survey2, questions: questions2)

      response = client.get("#{ANSWERS_BASE}?survey_id=#{survey1.id}", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)

      response_json.as_a.map(&.["id"].as_i).sort!.should eq(answers1.map(&.id.not_nil!).sort!)
      response_json.as_a.map(&.["id"].as_i).sort!.should_not eq(answers2.map(&.id.not_nil!).sort!)
    end

    it "should return a list of answers that were created in a range" do
      questions = SurveyHelper.create_questions
      survey = SurveyHelper.create_survey(question_order: questions.map(&.id))

      Timecop.scale(600) # 1 second == 10 minutes

      answers1 = SurveyHelper.create_answers(survey: survey, questions: questions)
      sleep(200.milliseconds) # advance time 2 minutes
      answers2 = SurveyHelper.create_answers(survey: survey, questions: questions)
      sleep(200.milliseconds) # advance time 2 minutes
      answers3 = SurveyHelper.create_answers(survey: survey, questions: questions)

      Timecop.scale(1) # 1 second == 1 second

      after_time = 3.minutes.ago.to_unix
      before_time = 1.minutes.ago.to_unix

      response = client.get("#{ANSWERS_BASE}?created_after=#{after_time}&created_before=#{before_time}", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)

      response_json.as_a.map(&.["id"].as_i).sort!.should_not eq(answers1.map(&.id.not_nil!).sort!)
      response_json.as_a.map(&.["id"].as_i).sort!.should eq(answers2.map(&.id.not_nil!).sort!)
      response_json.as_a.map(&.["id"].as_i).sort!.should_not eq(answers3.map(&.id.not_nil!).sort!)
    end

    it "should return a list of answers that were created after a specific time" do
      questions = SurveyHelper.create_questions
      survey = SurveyHelper.create_survey(question_order: questions.map(&.id))

      Timecop.scale(600) # 1 second == 10 minutes

      answers1 = SurveyHelper.create_answers(survey: survey, questions: questions)
      sleep(200.milliseconds) # advance time 2 minutes
      answers2 = SurveyHelper.create_answers(survey: survey, questions: questions)
      sleep(200.milliseconds) # advance time 2 minutes
      answers3 = SurveyHelper.create_answers(survey: survey, questions: questions)

      Timecop.scale(1) # 1 second == 1 second

      after_time = 3.minutes.ago.to_unix

      response = client.get("#{ANSWERS_BASE}?created_after=#{after_time}", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)

      response_json.as_a.map(&.["id"].as_i).sort!.should_not eq(answers1.map(&.id.not_nil!).sort!)
      response_json.as_a.map(&.["id"].as_i).sort!.should eq((answers2.map(&.id.not_nil!) + answers3.map(&.id.not_nil!)).sort)
    end

    it "should return a list of answers that were created before a specific time" do
      questions = SurveyHelper.create_questions
      survey = SurveyHelper.create_survey(question_order: questions.map(&.id))

      Timecop.scale(600) # 1 second == 10 minutes

      answers1 = SurveyHelper.create_answers(survey: survey, questions: questions)
      sleep(200.milliseconds) # advance time 2 minutes
      answers2 = SurveyHelper.create_answers(survey: survey, questions: questions)
      sleep(200.milliseconds) # advance time 2 minutes
      answers3 = SurveyHelper.create_answers(survey: survey, questions: questions)

      Timecop.scale(1) # 1 second == 1 second

      before_time = 1.minutes.ago.to_unix

      response = client.get("#{ANSWERS_BASE}?created_before=#{before_time}", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)

      response_json.as_a.map(&.["id"].as_i).sort!.should eq((answers1.map(&.id.not_nil!) + answers2.map(&.id.not_nil!)).sort)
      response_json.as_a.map(&.["id"].as_i).sort!.should_not eq(answers3.map(&.id.not_nil!).sort!)
    end
  end

  describe "#create" do
    it "should create answers" do
      questions = SurveyHelper.create_questions
      survey = SurveyHelper.create_survey(question_order: questions.map(&.id))

      answers = [
        {
          question_id: questions[0].id,
          survey_id:   survey.id,
          type:        "single_choice",
          answer_json: {
            text: "Green",
          },
        },
        {
          question_id: questions[1].id,
          survey_id:   survey.id,
          type:        "single_choice",
          answer_json: {
            text: "Cat",
          },
        },
        {
          question_id: questions[2].id,
          survey_id:   survey.id,
          type:        "single_choice",
          answer_json: {
            text: "Pizza",
          },
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
          type:        "single_choice",
          answer_json: {
            text: "Cat",
          },
        },
        {
          question_id: questions[2].id,
          survey_id:   survey.id,
          type:        "single_choice",
          answer_json: {
            text: "Pizza",
          },
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
          type:        "single_choice",
          answer_json: {
            text: "Green",
          },
        },
        {
          question_id: questions[1].id,
          survey_id:   survey2.id,
          type:        "single_choice",
          answer_json: {
            text: "Cat",
          },
        },
      ].to_json

      response = client.post(ANSWERS_BASE, headers: headers, body: answers)
      response.status_code.should eq(400)
    end
  end
end

ANSWERS_BASE = Surveys::Answers.base_route
