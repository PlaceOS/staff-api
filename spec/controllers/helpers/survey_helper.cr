module SurveyHelper
  extend self

  def question_responders
    [
      Survey::Question::Responder.from_json({
        title:    "What is your favorite color?",
        type:     "single_choice",
        required: true,
        choices:  [
          {title: "Red"},
          {title: "Blue"},
          {title: "Green"},
        ],
      }.to_json),
      Survey::Question::Responder.from_json({
        title:   "What is your favorite animal?",
        type:    "single_choice",
        choices: [
          {title: "Dog"},
          {title: "Cat"},
          {title: "Bird"},
        ],
      }.to_json),
      Survey::Question::Responder.from_json({
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
    question_responders.map { |q| q.to_question.save! }
  end

  def survey_responder(question_order = [] of Int64, zone_id = nil, building_id = nil)
    Survey::Responder.from_json({
      title:       "New Survey",
      description: "This is a new survey",
      zone_id:     zone_id,
      building_id: building_id,
      pages:       [{
        title:          "Page 1",
        description:    "This is page 1",
        question_order: question_order,
      }],
    }.to_json)
  end

  def create_survey(question_order = [] of Int64, zone_id = nil, building_id = nil)
    survey_responder(question_order, zone_id, building_id).to_survey.save!
  end
end
