# Survey answers, the responses submitted for a survey, one answer per question
class Surveys::Answers < Application
  include Utils::SurveyHelpers

  base "/api/staff/v1/surveys/answers"

  # Lists the answers submitted to this domain's surveys, optionally filtered by survey and creation time.
  # Each answer includes its question_id, survey_id, type and answer_json.
  # When no time range is given, all answers up to now are returned. Any authenticated user can list answers.
  @[AC::Route::GET("/")]
  def index(
    @[AC::Param::Info(description: "only return answers submitted for this survey id", example: "1234")]
    survey_id : Int64? = nil,
    @[AC::Param::Info(description: "only return answers created at or after this time, as a unix timestamp in seconds (defaults to 0)", example: "1661743123")]
    created_after : Int64? = nil,
    @[AC::Param::Info(description: "only return answers created at or before this time, as a unix timestamp in seconds (defaults to now)", example: "1661743123")]
    created_before : Int64? = nil,
  ) : Array(Survey::Answer)
    Survey::Answer.list(survey_id, created_after, created_before, survey_authority_id)
  end

  # Submits a set of answers to a survey, i.e. one person's response. Any authenticated user can submit answers.
  # The body is an array of answers, each with survey_id, question_id, type and answer_json; all must share the same survey_id.
  # Every required question in the survey must be answered, otherwise 400 is returned listing the missing question ids.
  # Returns the saved answers, or 404 if the survey isn't one of this domain's.
  @[AC::Route::POST("/", body: :answers, status_code: HTTP::Status::CREATED)]
  def create(answers : Array(Survey::Answer)) : Array(Survey::Answer)
    survey_id = answers.first?.try(&.survey_id)
    raise Error::BadRequest.new("At least one answer, with a survey_id, is required") unless survey_id
    raise Error::BadRequest.new("All answers must be for the same survey") unless answers.all? { |answer| answer.survey_id == survey_id }
    find_survey!(survey_id)

    missing = Survey.missing_answers(survey_id, answers)
    raise Error::BadRequest.new("Missing required answers for questions: #{missing.join(", ")}") unless missing.empty?

    answers.each do |answer|
      answer.save! rescue raise Error::ModelValidation.new(answer.errors.map { |error| {field: error.field.to_s, reason: error.message}.as({field: String?, reason: String}) }, "error validating answer data")
    end
    answers
  end
end
