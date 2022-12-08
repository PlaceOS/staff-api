class Survey
  class Invitation
    include Clear::Model

    column id : Int64, primary: true, presence: false
    column token : String
    column email : String
    column sent : Bool = false

    belongs_to survey : Survey

    timestamps

    struct Responder
      include JSON::Serializable

      getter id : Int64?
      getter survey_id : Int64?
      getter token : String?
      getter email : String?
      getter sent : Bool = false

      def initialize(@id, @survey_id, @token, @email, @sent = false)
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

    def validate
      validate_columns
    end

    private def validate_columns
      add_error("survey_id", "must be defined") unless survey_id_column.defined?
      add_error("token", "must be defined") unless token_column.defined?
      add_error("email", "must be defined") unless email_column.defined?
      add_error("sent", "must be defined") unless sent_column.defined?
    end
  end
end
