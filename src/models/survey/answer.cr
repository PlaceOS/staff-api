class Survey::Answer
  include Clear::Model

  column id : Int64, primary: true, presence: false
  column answer : String

  belongs_to question : Survey::Question
  belongs_to survey : Survey

  timestamps
end
