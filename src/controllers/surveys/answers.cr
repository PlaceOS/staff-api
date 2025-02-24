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
    created_before : Int64? = nil,
  ) : Array(Survey::Answer)
    Survey::Answer.list(survey_id, created_after, created_before)
  end

  # creates a new survey answer
  @[AC::Route::POST("/", body: :answers, status_code: HTTP::Status::CREATED)]
  def create(answers : Array(Survey::Answer)) : Array(Survey::Answer)
    survey_id = answers.first.survey_id.not_nil!
    raise Error::BadRequest.new("All answers must be for the same survey") unless answers.all? { |answer| answer.survey_id == survey_id }

    missing = Survey.missing_answers(survey_id, answers)
    raise Error::BadRequest.new("Missing required answers for questions: #{missing.join(", ")}") unless missing.empty?

    answers.each do |answer|
      answer.save! rescue raise Error::ModelValidation.new(answer.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating answer data")
    end
    answers
  end
end
