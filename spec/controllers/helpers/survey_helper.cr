module SurveyHelper
  extend self

  def question_responders
    [
      Survey::Question.from_json({
        title:    "What is your favorite color?",
        type:     "single_choice",
        required: true,
        choices:  [
          {title: "Red"},
          {title: "Blue"},
          {title: "Green"},
        ],
      }.to_json),
      Survey::Question.from_json({
        title:   "What is your favorite animal?",
        type:    "single_choice",
        choices: [
          {title: "Dog"},
          {title: "Cat"},
          {title: "Bird"},
        ],
      }.to_json),
      Survey::Question.from_json({
        title:   "What is your favorite food?",
        type:    "single_choice",
        choices: [
          {title: "Pizza"},
          {title: "Burgers"},
          {title: "Salad"},
        ],
      }.to_json),
    ]
  end

  def create_questions : Array(Survey::Question)
    question_responders.map { |q| q.save!.reload! }
  end

  def survey_responder(question_order = [] of Int64, zone_id = nil, building_id = nil, trigger = nil)
    Survey.from_json({
      title:       "New Survey",
      description: "This is a new survey",
      zone_id:     zone_id,
      building_id: building_id,
      trigger:     trigger,
      pages:       [{
        title:          "Page 1",
        description:    "This is page 1",
        question_order: question_order,
      }],
    }.to_json)
  end

  def create_survey(question_order = [] of Int64, zone_id = nil, building_id = nil, trigger = nil)
    survey_responder(question_order, zone_id, building_id, trigger).save!
  end

  def answer_responders(survey = create_survey, questions = create_questions)
    [
      Survey::Answer.from_json({
        question_id: questions[0].id,
        survey_id:   survey.id,
        type:        "single_choice",
        answer_json: {
          text: "Green",
        },
      }.to_json),
      Survey::Answer.from_json({
        question_id: questions[1].id,
        survey_id:   survey.id,
        type:        "single_choice",
        answer_json: {
          text: "Cat",
        },
      }.to_json),
      Survey::Answer.from_json({
        question_id: questions[2].id,
        survey_id:   survey.id,
        type:        "single_choice",
        answer_json: {
          text: "Pizza",
        },
      }.to_json),
    ]
  end

  def create_answers(survey = create_survey, questions = create_questions)
    answer_responders(survey, questions).map(&.save!)
  end

  def invitation_responder(survey = create_survey, email = "someone@spec.test", sent = false)
    Survey::Invitation.from_json({
      survey_id: survey.id,
      email:     email,
      sent:      sent,
    }.to_json)
  end

  def create_invitation(survey = create_survey, email = "someone@spec.test", sent = false)
    invitation_responder(survey, email, sent).save!
  end
end
