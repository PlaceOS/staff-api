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

  def create_questions(authority_id : String = self.authority_id) : Array(Survey::Question)
    question_responders.map do |question|
      question.authority_id = authority_id
      question.save!.reload!
    end
  end

  # the authority surveys belong to in specs, that of the mock tenant's domain
  def authority_id : String
    Mock::Token.generate_auth_user(false, false)
    PlaceOS::Model::Authority.find_by_domain("toby.staff-api.dev").not_nil!.id.as(String)
  end

  # ensures a zone with this id exists, surveys reference zones by foreign key
  def zone(id : String = "zone-survey-#{Random::Secure.hex(4)}") : String
    unless PlaceOS::Model::Zone.find?(id)
      zone = PlaceOS::Model::Zone.new(name: id)
      zone.id = id
      zone.save!
    end
    id
  end

  # a survey needs a zone_id or building_id, a new zone is used when neither is given
  def survey_responder(question_order = [] of Int64, zone_id = nil, building_id = nil, trigger = nil)
    zone_id = zone if zone_id.nil? && building_id.nil?
    zone_id.try { |id| zone(id) }
    building_id.try { |id| zone(id) }
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

  def create_survey(question_order = [] of Int64, zone_id = nil, building_id = nil, trigger = nil, authority_id : String = self.authority_id)
    survey = survey_responder(question_order, zone_id, building_id, trigger)
    survey.authority_id = authority_id
    survey.save!
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
