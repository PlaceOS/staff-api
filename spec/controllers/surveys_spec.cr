require "../spec_helper"
require "./helpers/survey_helper"

describe Surveys, tags: ["survey"] do
  Spec.before_each { Survey.truncate }

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of surveys" do
      survey = SurveyHelper.create_survey

      response = client.get(SURVEY_BASE, headers: headers)
      response.status_code.should eq(200)
      JSON.parse(response.body).as_a.first.as_h["id"].should eq(survey.id)
    end

    it "should return a list of surveys filtered by zone_id" do
      _survey1 = SurveyHelper.create_survey(zone_id: "1")
      survey2 = SurveyHelper.create_survey(zone_id: "2")

      response = client.get("#{SURVEY_BASE}?zone_id=2", headers: headers)
      response.status_code.should eq(200)
      JSON.parse(response.body).as_a.first.as_h["id"].should eq(survey2.id)
    end

    it "should return a list of surveys filtered by building_id" do
      survey1 = SurveyHelper.create_survey(building_id: "1")
      _survey2 = SurveyHelper.create_survey(building_id: "2")

      response = client.get("#{SURVEY_BASE}?building_id=1", headers: headers)
      response.status_code.should eq(200)
      JSON.parse(response.body).as_a.first.as_h["id"].should eq(survey1.id)
    end
  end

  describe "#create" do
    it "should create a survey" do
      survey = SurveyHelper.survey_responder.to_json

      response = client.post(SURVEY_BASE, headers: headers, body: survey)
      response.status_code.should eq(201)
      response_body = JSON.parse(response.body)
      response_body["title"].should eq("New Survey")
    end
  end

  describe "#update" do
    it "should update a survey" do
      survey = SurveyHelper.create_survey
      update = {title: "Updated Title"}.to_json

      response = client.put("#{SURVEY_BASE}/#{survey.id}", headers: headers, body: update)
      response.status_code.should eq(200)
      JSON.parse(response.body)["title"].should eq("Updated Title")
    end
  end

  describe "#show" do
    it "should return a survey" do
      survey = SurveyHelper.create_survey

      response = client.get("#{SURVEY_BASE}/#{survey.id}", headers: headers)
      response.status_code.should eq(200)
      response.body.should eq(survey.to_json)
    end

    it "should maintain the question_order" do
      questions = SurveyHelper.create_questions
      question_order = questions[0..1].map(&.id).shuffle!
      survey = SurveyHelper.create_survey(question_order: question_order)

      response = client.get("#{SURVEY_BASE}/#{survey.id}", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json["pages"].as_a.first["question_order"].should eq(question_order)
    end
  end

  describe "#destroy" do
    it "should delete a survey" do
      survey = SurveyHelper.create_survey
      response = client.delete("#{SURVEY_BASE}/#{survey.id}", headers: headers)
      response.status_code.should eq(202)
    end
  end
end

SURVEY_BASE = Surveys.base_route
