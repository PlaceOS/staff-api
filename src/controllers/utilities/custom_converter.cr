require "json"

module Clear::Model::Converter::EmailConverter
  private alias Email = PlaceOS::Model::Email

  def self.to_column(x) : Email?
    case x
    when String
      Email.new(x)
    when ::JSON::PullParser
      Email.new(x)
    when Email
      x
    when Nil
      nil
    else
      raise Clear::ErrorMessages.converter_error(x.class.name, "PlaceOS::Model::Email")
    end
  end

  def self.to_db(x : Email?)
    return nil if x.nil?
    x.to_s
  end
end

Clear::Model::Converter.add_converter("PlaceOS::Model::Email", Clear::Model::Converter::EmailConverter)
