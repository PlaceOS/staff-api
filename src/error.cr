class Error < Exception
  getter message

  def initialize(@message : String = "")
    super(message)
  end

  class Unauthorized < Error
  end

  class Forbidden < Error
  end

  class BookingConflict < Error
    def initialize(message = "Conflicting booking")
      super(message)
    end
  end

  class BookingLimit < Error
    getter limit

    def initialize(@limit : Int32, message = "Booking limit reached")
      super(message)
    end
  end

  class InvalidParams < Error
    def initialize(@params : Params, message = "")
      super(message)
    end

    getter params
  end

  class Session < Error
    getter error_code

    def initialize(@error_code : Api::Session::ErrorCode, message = "")
      super(message)
    end

    def error_response(request_id : String = "") : Api::Session::Response
      Api::Session::Response.new(
        id: request_id,
        type: Api::Session::Response::Type::Error,
        error_code: error_code.to_i,
        message: message,
      )
    end
  end
end
