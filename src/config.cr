require "./logging"

require "crystal/dwarf/info"

# debugging dwarf file issues
struct Crystal::DWARF::Info
  private def read_attribute_value(form, attr)
    case form
    when FORM::Addr
      case address_size
      when 4 then @io.read_bytes(UInt32)
      when 8 then @io.read_bytes(UInt64)
      else        raise "Invalid address size: #{address_size}"
      end
    when FORM::Block1
      len = @io.read_byte.not_nil!
      @io.read_fully(bytes = Bytes.new(len.to_i))
      bytes
    when FORM::Block2
      len = @io.read_bytes(UInt16)
      @io.read_fully(bytes = Bytes.new(len.to_i))
      bytes
    when FORM::Block4
      len = @io.read_bytes(UInt32)
      @io.read_fully(bytes = Bytes.new(len.to_i64))
      bytes
    when FORM::Block
      len = DWARF.read_unsigned_leb128(@io)
      @io.read_fully(bytes = Bytes.new(len))
      bytes
    when FORM::Data1
      @io.read_byte.not_nil!
    when FORM::Data2
      @io.read_bytes(UInt16)
    when FORM::Data4
      @io.read_bytes(UInt32)
    when FORM::Data8
      @io.read_bytes(UInt64)
    when FORM::Data16
      @io.read_bytes(UInt64)
      @io.read_bytes(UInt64)
    when FORM::Sdata
      DWARF.read_signed_leb128(@io)
    when FORM::Udata
      DWARF.read_unsigned_leb128(@io)
    when FORM::ImplicitConst
      attr.value
    when FORM::Exprloc
      len = DWARF.read_unsigned_leb128(@io)
      @io.read_fully(bytes = Bytes.new(len))
      bytes
    when FORM::Flag
      @io.read_byte == 1
    when FORM::FlagPresent
      true
    when FORM::SecOffset
      read_ulong
    when FORM::Ref1
      @ref_offset + @io.read_byte.not_nil!.to_u64
    when FORM::Ref2
      @ref_offset + @io.read_bytes(UInt16).to_u64
    when FORM::Ref4
      @ref_offset + @io.read_bytes(UInt32).to_u64
    when FORM::Ref8
      @ref_offset + @io.read_bytes(UInt64).to_u64
    when FORM::RefUdata
      @ref_offset + DWARF.read_unsigned_leb128(@io)
    when FORM::RefAddr
      read_ulong
    when FORM::RefSig8
      @io.read_bytes(UInt64)
    when FORM::String
      @io.gets('\0', chomp: true).to_s
    when FORM::Strp, FORM::LineStrp
      # HACK: A call to read_ulong is failing with an .ud2 / Illegal instruction: 4 error
      #       Calling with @[AlwaysInline] makes no difference.
      if @dwarf64
        @io.read_bytes(UInt64)
      else
        @io.read_bytes(UInt32)
      end
    when FORM::Indirect
      form = FORM.new(DWARF.read_unsigned_leb128(@io))
      read_attribute_value(form, attr)
    else

      raise "Unknown DW_FORM_#{form.to_s.underscore}"
    end
  end
end

# Application dependencies
require "action-controller"
require "auto_initialize"
require "active-model"
require "clear"

require "./constants"
require "./error"
require "./controllers/application"
require "./models/*"
require "./migrations/*"
require "./controllers/*"

# Add telemetry after application code
require "./telemetry"

# Configure Clear ORM
Clear::SQL.init(App::PG_DATABASE_URL)
Clear::Migration::Manager.instance.apply_all

# Server required after application controllers
require "action-controller/server"

# Filter out sensitive params that shouldn't be logged
filter_params = ["password", "bearer_token"]
keeps_headers = ["X-Request-ID"]

# Add handlers that should run before your application
ActionController::Server.before(
  ActionController::ErrorHandler.new(App.running_in_production?, keeps_headers),
  ActionController::LogHandler.new(filter_params)
)

# Configure session cookies
# NOTE:: Change these from defaults
ActionController::Session.configure do |settings|
  settings.key = App::COOKIE_SESSION_KEY
  settings.secret = App::COOKIE_SESSION_SECRET
  # HTTPS only:
  settings.secure = App.running_in_production?
end
