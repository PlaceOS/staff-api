class Surveys::Answers < Application
  base "/api/staff/v1/surveys/answers"

  # returns a list of answers
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(description: "the survey id to get answers for", example: "1234")]
    survey_id : Int64? = nil
  ) : Array(Survey::Answer::Responder)
    query = Survey::Answer.query.select("id, question_id, survey_id, answer_text, answer_json")
    query.where(survey_id: survey_id) if survey_id

    query.to_a.map(&.as_json)
  end

  # creates a new survey answer
  @[AC::Route::POST("/", body: :answer_body, status_code: HTTP::Status::CREATED)]
  def create(answer_body : Array(Survey::Answer::Responder)) : Array(Survey::Answer::Responder)
    answers = answer_body.map(&.to_answer)

    survey_id = answers.first.survey_id
    raise Error::BadRequest.new("All answers must be for the same survey") unless answers.all? { |answer| answer.survey_id == survey_id }

    all_survey_questions = Survey.find!(survey_id).question_ids
    required_questions = Survey::Question
      .query.select("id")
      .where { id.in?(all_survey_questions) }
      .where { required == true }
      .to_a.map(&.id)

    missing = required_questions - answers.map(&.question_id)
    raise Error::BadRequest.new("Missing required answers for questions: #{missing.join(", ")}") if missing.any?

    answers.each do |answer|
      raise Error::ModelValidation.new(answer.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating answer data") if !answer.save
    end
    answers.map(&.as_json)
  end
end
