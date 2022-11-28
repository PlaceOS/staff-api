class Surveys::Answers < Application
  base "/api/staff/v1/surveys/answers"

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
