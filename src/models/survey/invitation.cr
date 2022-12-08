class Survey
  class Invitation
    include Clear::Model

    column id : Int64, primary: true, presence: false
    column token : String
    column email : String
    column sent : Bool = false

    timestamps

    struct Responder
      include JSON::Serializable

      getter id : Int64?
      getter token : String? = nil
      getter email : String? = nil
      getter sent : Bool = false

      def initialize(@id, @token = nil, @email = nil, @sent = false)
      end

      def to_invitation(update : Bool = false)
        invitation = Survey::Invitation.new
        {% for key in [:token, :email, :sent] %}
            invitation.{{key.id}} = self.{{key.id}}.not_nil! unless self.{{key.id}}.nil?
          {% end %}

        invitation
      end
    end

    def as_json
      Responder.new(
        id: self.id,
        token: self.token,
        email: self.email,
        sent: self.sent,
      )
    end

    def validate
      validate_columns
    end

    private def validate_columns
      add_error("token", "must be defined") unless token_column.defined?
      add_error("email", "must be defined") unless email_column.defined?
      add_error("sent", "must be defined") unless sent_column.defined?
    end
  end
end
