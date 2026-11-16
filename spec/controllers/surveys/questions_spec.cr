require "../../spec_helper"
require "../helpers/survey_helper"

describe Surveys::Questions, tags: ["survey"] do
  Spec.before_each { Survey::Question.truncate }

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

    it "should filter on deleted=true" do
      questions = SurveyHelper.create_questions
      questions.first.soft_delete

      response = client.get("#{QUESTIONS_BASE}?deleted=true", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)

      response_json.as_a.map(&.["id"]).should contain(questions[0].id)
      response_json.as_a.map(&.["id"]).should_not contain(questions[1].id)
      response_json.as_a.map(&.["id"]).should_not contain(questions[2].id)

      response_json.as_a.find! { |q| q["id"] == questions[0].id }["deleted"].should be_true
    end

    it "should filter on deleted=false" do
      questions = SurveyHelper.create_questions
      questions.first.soft_delete

      response = client.get("#{QUESTIONS_BASE}?deleted=false", headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["id"]).should_not contain(questions[0].id)
      response_json.as_a.map(&.["id"]).should contain(questions[1].id)
      response_json.as_a.map(&.["id"]).should contain(questions[2].id)

      response_json.as_a.find! { |q| q["id"] == questions[1].id }["deleted"].should be_false
      response_json.as_a.find! { |q| q["id"] == questions[2].id }["deleted"].should be_false
    end

    it "should include soft-deleted question by default" do
      questions = SurveyHelper.create_questions
      questions.first.soft_delete

      response = client.get(QUESTIONS_BASE, headers: headers)
      response.status_code.should eq(200)
      response_json = JSON.parse(response.body)
      response_json.as_a.map(&.["id"]).should contain(questions[0].id)
      response_json.as_a.map(&.["id"]).should contain(questions[1].id)
      response_json.as_a.map(&.["id"]).should contain(questions[2].id)

      response_json.as_a.find! { |q| q["id"] == questions[0].id }["deleted"].should be_true
      response_json.as_a.find! { |q| q["id"] == questions[1].id }["deleted"].should be_false
      response_json.as_a.find! { |q| q["id"] == questions[2].id }["deleted"].should be_false
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
      it "edits the question in place when only the wording changes" do
        questions = SurveyHelper.create_questions
        survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
        _answers = SurveyHelper.create_answers(survey: survey, questions: questions)

        update = {title: "Updated Title", tags: ["reworded"]}.to_json

        response = client.put("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers, body: update)
        response.status_code.should eq(200)
        response_body = JSON.parse(response.body)
        response_body["title"].should eq("Updated Title")
        response_body["id"].should eq(questions.first.id)
        Survey::Question.find!(questions.first.id).deleted_at.should be_nil
      end

      it "creates a new version, used by the surveys, when what is asked changes" do
        questions = SurveyHelper.create_questions
        survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
        _answers = SurveyHelper.create_answers(survey: survey, questions: questions)
        old_id = questions.first.id.as(Int64)

        update = {choices: [{title: "Red"}, {title: "Blue"}]}.to_json

        response = client.put("#{QUESTIONS_BASE}/#{old_id}", headers: headers, body: update)
        response.status_code.should eq(200)
        response_body = JSON.parse(response.body)
        new_id = response_body["id"].as_i64
        new_id.should_not eq(old_id)
        response_body["previous_question_id"].should eq(old_id)

        Survey::Question.find!(new_id).deleted_at.should be_nil
        Survey::Question.find!(old_id).deleted_at.should_not be_nil
        Survey.find!(survey.id).question_ids.first.should eq(new_id)
        # answers stay with the version they answered
        Survey::Answer.where(question_id: old_id).count.should eq(1)
        Survey::Answer.where(question_id: new_id).count.should eq(0)
      end

      it "moves the answers to the new version when migrate_answers is set" do
        questions = SurveyHelper.create_questions
        survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
        _answers = SurveyHelper.create_answers(survey: survey, questions: questions)
        old_id = questions.first.id.as(Int64)

        update = {required: false}.to_json

        response = client.put("#{QUESTIONS_BASE}/#{old_id}?migrate_answers=true", headers: headers, body: update)
        response.status_code.should eq(200)
        new_id = JSON.parse(response.body)["id"].as_i64
        new_id.should_not eq(old_id)

        Survey::Answer.where(question_id: new_id).count.should eq(1)
        Survey::Answer.where(question_id: old_id).count.should eq(0)
      end
    end

    it "hides another domain's questions" do
      other = PlaceOS::Model::Generator.authority(domain: "question-other-#{Random::Secure.hex(4)}.dev").save!.id.as(String)
      question = SurveyHelper.question_responders.first
      question.authority_id = other
      question.save!

      client.get("#{QUESTIONS_BASE}/#{question.id}", headers: headers).status_code.should eq(404)
      client.put("#{QUESTIONS_BASE}/#{question.id}", headers: headers, body: {title: "taken"}.to_json).status_code.should eq(404)
      JSON.parse(client.get(QUESTIONS_BASE, headers: headers).body).as_a.map(&.["id"]).should_not contain(question.id)

      # nor can a survey use them
      body = SurveyHelper.survey_responder(question_order: [question.id.as(Int64)]).to_json
      client.post(Surveys.base_route, headers: headers, body: body).status_code.should eq(422)
    end
  end

  describe "#show" do
    it "should return a question" do
      questions = SurveyHelper.create_questions

      response = client.get("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
      response.status_code.should eq(200)
      response.body.should eq(questions.first.to_json)
    end

    it "should show deleted=true for a soft-deleted questions" do
      questions = SurveyHelper.create_questions
      questions.first.soft_delete

      response = client.get("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
      response.status_code.should eq(200)
      response_body = JSON.parse(response.body)
      response_body["deleted"].should be_true
    end

    it "should show deleted=false for a questions that is not deleted" do
      questions = SurveyHelper.create_questions

      response = client.get("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
      response.status_code.should eq(200)
      response_body = JSON.parse(response.body)
      response_body["deleted"].should be_false
    end
  end

  describe "#destroy" do
    context "when there are no linked answers" do
      it "should delete a question" do
        questions = SurveyHelper.create_questions

        response = client.delete("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
        response.status_code.should eq(202)
        Survey::Question.find?(questions.first.id).should be_nil
      end
    end

    context "when there are linked answers" do
      it "should soft delete the question" do
        questions = SurveyHelper.create_questions
        survey = SurveyHelper.create_survey(question_order: questions.map(&.id))
        _answers = SurveyHelper.create_answers(survey: survey, questions: questions)

        response = client.delete("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
        response.status_code.should eq(202)
        Survey::Question.find(questions.first.id).not_nil!.deleted_at.should_not be_nil
      end
    end

    context "when the question is in a survey" do
      it "should soft delete the question" do
        questions = SurveyHelper.create_questions
        _survey = SurveyHelper.create_survey(question_order: questions.map(&.id))

        response = client.delete("#{QUESTIONS_BASE}/#{questions.first.id}", headers: headers)
        response.status_code.should eq(202)
        Survey::Question.find(questions.first.id).not_nil!.deleted_at.should_not be_nil
      end
    end
  end
end

QUESTIONS_BASE = Surveys::Questions.base_route
