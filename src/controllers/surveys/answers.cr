class Surveys::Answers < Application
  base "/api/staff/v1/surveys/answers"

  # returns a list of answers
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(description: "the survey id to get answers for", example: "1234")]
    survey_id : Int64? = nil,
    @[AC::Param::Info(description: "filters answers that were created after the unix epoch specified", example: "1661743123")]
    created_after : Int64? = nil,
    @[AC::Param::Info(description: "filters answers that were created before the unix epoch specified", example: "1661743123")]
    created_before : Int64? = nil
  ) : Array(Survey::Answer::Responder)
    query = Survey::Answer.query.select("id, question_id, survey_id, type, answer_json")

    # filter
    query = query.where(survey_id: survey_id) if survey_id
    after_time = created_after ? Time.unix(created_after) : Time.unix(0)
    before_time = created_before ? Time.unix(created_before) : Time.local
    query = query.where { created_at.between(after_time, before_time) }

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
    raise Error::BadRequest.new("Missing required answers for questions: #{missing.join(", ")}") if !missing.empty?

    answers.each do |answer|
      raise Error::ModelValidation.new(answer.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating answer data") if !answer.save
    end
    answers.map(&.as_json)
  end
end
