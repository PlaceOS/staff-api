# Scoping and permissions shared by the survey controllers.
#
# Surveys and questions belong to the authority of the request's domain. Those created before
# they had an authority are adopted by the first authority to access them. Authenticated users can
# view surveys and submit answers. Admins and support can edit everything, other users must be able
# to manage the survey's zones (questions have no zones, so only admins and support edit them).
module Utils::SurveyHelpers
  @survey_authority_id : String? = nil

  # the authority surveys are scoped to, adopting any surveys and questions that predate authorities
  def survey_authority_id : String
    @survey_authority_id ||= begin
      authority_id = current_authority.try(&.id)
      raise Error::NotFound.new("no authority configured for #{request.hostname}") unless authority_id
      Survey.adopt_unowned(authority_id)
      Survey::Question.adopt_unowned(authority_id)
      authority_id
    end
  end

  # finds a question of the current authority, another authority's questions are not found
  def find_question!(id : Int64) : Survey::Question
    authority_id = survey_authority_id
    question = Survey::Question.find?(id)
    raise Error::NotFound.new("question #{id} not found") unless question && question.authority_id == authority_id
    question
  end

  # survey pages may only use the current authority's questions
  def confirm_questions!(pages : Array(Survey::Page)) : Nil
    ids = pages.flat_map(&.question_order).uniq!
    return if ids.empty?
    found = Survey::Question.where(id: ids, authority_id: survey_authority_id).count
    return if found == ids.size
    raise Error::ModelValidation.new([{field: "pages", reason: "question ids must be questions of this domain"}.as({field: String?, reason: String})], "error validating survey data")
  end

  # finds a survey of the current authority, another authority's surveys are not found
  def find_survey!(id : Int64) : Survey
    # resolved first, so a survey without an authority is adopted before it's loaded
    authority_id = survey_authority_id
    survey = Survey.find?(id)
    raise Error::NotFound.new("survey #{id} not found") unless survey && survey.authority_id == authority_id
    survey
  end

  # admins and support can edit any survey, other users must manage one of its zones
  def can_edit_survey?(zones : Array(String)) : Bool
    return true if is_support?
    return false if zones.empty? || user_token.guest_scope?
    check_access(current_user.groups, zones).can_manage?
  end

  def confirm_survey_edit!(zones : Array(String)) : Nil
    raise Error::Forbidden.new("not permitted to edit surveys in zones #{zones}") unless can_edit_survey?(zones)
  end
end
