require "../../spec_helper"
require "../helpers/spec_clean_up"
require "../helpers/survey_helper"

describe Surveys::Questions, tags: ["survey"] do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of questions" do
      questions = SurveyHelper.create_questions

      response = client.get(QUESTIONS_BASE, headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["title"]).should eq(questions.map(&.title))
    end

    it "should return a list of questions for a survey" do
      questions = SurveyHelper.create_questions
      question_order = questions[0..1].map(&.id).shuffle!
      survey = SurveyHelper.create_survey(question_order: question_order)

      response = client.get("#{QUESTIONS_BASE}?survey_id=#{survey.id}", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["id"]).should contain(questions[0].id)
      response_json.as_a.map(&.["id"]).should contain(questions[1].id)
      response_json.as_a.map(&.["id"]).should_not contain(questions[2].id)
    end

    pending "should filter on deleted" do
    end
  end

  describe "#create" do
    it "should create a question" do
      questions = SurveyHelper.question_responders
      question = questions[0].to_json

      response = client.post(QUESTIONS_BASE, headers: headers, body: question)
      response.status_code.should eq(201)
      response_body = JSON.parse(response.body)
      response_body["title"].should eq(questions[0].title)
    end
  end

  describe "#update" do
    context "when there are no linked answers" do
      it "should update a question" do
        questions = SurveyHelper.create_questions
        update = {title: "Updated Title"}.to_json

        response = client.put("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers, body: update)
        response.status_code.should eq(200)
        response_body = JSON.parse(response.body)
        response_body["title"].should eq("Updated Title")
      end
    end

    context "when there are linked answers" do
      it "should create a new question" do
        questions = SurveyHelper.create_questions
        survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
        answers = SurveyHelper.create_answers(survey: survey, questions: questions)

        update = {title: "Updated Title"}.to_json

        response = client.put("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers, body: update)
        response.status_code.should eq(200)
        response_body = JSON.parse(response.body)
        response_body["title"].should eq("Updated Title")
        response_body["id"].should_not eq(questions.first.id)
      end

      it "should soft delete the question" do
        questions = SurveyHelper.create_questions
        survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
        answers = SurveyHelper.create_answers(survey: survey, questions: questions)

        update = {title: "Updated Title"}.to_json

        response = client.put("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers, body: update)
        response.status_code.should eq(200)
        response_body = JSON.parse(response.body)
        response_body["title"].should eq("Updated Title")
        response_body["id"].should_not eq(questions.first.id)
        Survey::Question.find(response_body["id"]).not_nil!.deleted_at.should be_nil
        Survey::Question.find(questions.first.id).not_nil!.deleted_at.should_not be_nil
      end

      pending "should replace the question on surveys" do
        # if query param
      end
    end
  end

  describe "#show" do
    it "should return a question" do
      questions = SurveyHelper.create_questions

      response = client.get("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
      response.status_code.should eq(200)
      response.body.should eq(questions.first.as_json.to_json)
    end
  end

  describe "#destroy" do
    context "when there are no linked answers" do
      it "should delete a question" do
        questions = SurveyHelper.create_questions

        response = client.delete("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
        response.status_code.should eq(202)
        Survey::Question.find(questions.first.id).should be_nil
      end
    end

    context "when there are linked answers" do
      it "should soft delete the question" do
        questions = SurveyHelper.create_questions
        survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
        answers = SurveyHelper.create_answers(survey: survey, questions: questions)

        response = client.delete("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
        response.status_code.should eq(202)
        Survey::Question.find(questions.first.id).not_nil!.deleted_at.should_not be_nil
      end

      pending "should remove the question from surveys" do
        # if query param
        # else it should fail
      end
    end
  end
end

QUESTIONS_BASE = Surveys::Questions.base_route
