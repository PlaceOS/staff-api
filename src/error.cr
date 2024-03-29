class Error < Exception
  getter message

  def initialize(@message : String = "")
    super(message)
  end

  class TooManyRequests < Error
  end

  class BadRequest < Error
  end

  class Unauthorized < Error
  end

  class Forbidden < Error
  end

  class NotImplemented < Error
  end

  class NeedsAuthentication < Error
  end

  class NotAllowed < Error
  end

  class NotFound < Error
  end

  class BadUpstreamResponse < Error
  end

  class InconsistentState < Error
  end

  class ModelValidation < Error
    getter failures

    def initialize(@failures : Array(NamedTuple(field: String?, reason: String)), message : String)
      super(message)
    end
  end

  class BookingConflict < Error
    getter bookings

    def initialize(@bookings : Array(Booking), message = "Conflicting booking")
      super(message)
    end
  end

  class BookingLimit < Error
    getter limit
    getter bookings

    def initialize(@limit : Int32, @bookings : Array(Booking), message = "Booking limit reached")
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
