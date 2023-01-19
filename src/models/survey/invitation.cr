require "ulid"

class Survey
  class Invitation
    include Clear::Model
    self.table = "survey_invitations"

    column id : Int64, primary: true, presence: false
    column token : String, presence: false
    column email : String
    column sent : Bool, presence: false

    belongs_to survey : Survey

    timestamps

    before :create, :generate_token

    struct Responder
      include JSON::Serializable

      getter id : Int64?
      getter survey_id : Int64? = nil
      getter token : String? = nil
      getter email : String? = nil
      getter sent : Bool? = nil

      def initialize(@id, @survey_id = nil, @token = nil, @email = nil, @sent = nil)
      end

      def to_invitation(update : Bool = false)
        invitation = Survey::Invitation.new
        {% for key in [:survey_id, :token, :email, :sent] %}
            invitation.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
          {% end %}

        invitation
      end
    end

    def as_json
      Responder.new(
        id: self.id,
        survey_id: self.survey_id,
        token: self.token,
        email: self.email,
        sent: self.sent,
      )
    end

    def generate_token
      self.token = ULID.generate
    end

    def validate
      validate_columns
    end

    private def validate_columns
      add_error("survey_id", "must be defined") unless survey_id_column.defined?
      add_error("email", "must be defined") unless email_column.defined?
    end
  end
end
