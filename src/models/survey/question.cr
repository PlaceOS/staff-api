class Survey::Question
  include Clear::Model

  column id : Int64, primary: true, presence: false
  column title : String
  column description : String?
  column type : String
  column question_options : JSON::Any, presence: false

  has_many answers : Survey::Answer, foreign_key: "answer_id"
  # belongs_to surveys : Array(Survey)

  timestamps
end
