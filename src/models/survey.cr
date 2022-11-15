class Survey
  include Clear::Model

  column id : Int64, primary: true, presence: false
  column title : String
  column description : String?
  column question_order : Array(Int64)

  # has_many questions : Survey::Question, foreign_key: "survey_id"
  has_many answers : Survey::Answer, foreign_key: "answer_id"

  # before save
  # check that question_order is unique (no duplicate questions)

  timestamps
end
