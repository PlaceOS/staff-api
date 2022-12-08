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
    answers.each do |answer|
      raise Error::ModelValidation.new(answer.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating answer data") if !answer.create
    end
    answers.map(&.as_json)
  end
end
