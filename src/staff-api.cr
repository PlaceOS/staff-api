require "./constants"
require "option_parser"

# Server defaults
port = App::DEFAULT_PORT
host = App::DEFAULT_HOST
process_count = App::DEFAULT_PROCESS_COUNT

require "./config"

# Command line options
OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-b HOST", "--bind=HOST", "Specifies the server host") { |h| host = h }
  parser.on("-p PORT", "--port=PORT", "Specifies the server port") { |p| port = p.to_i }

  parser.on("-w COUNT", "--workers=COUNT", "Specifies the number of processes to handle requests") do |w|
    process_count = w.to_i
  end

  parser.on("-r", "--routes", "List the application routes") do
    ActionController::Server.print_routes
    exit 0
  end

  parser.on("-v", "--version", "Display the application version") do
    puts "#{App::NAME} v#{App::VERSION}"
    exit 0
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit 0
  end

  parser.on("-f", "--fix", "Fixes booking asset IDs as a once off") do
    success = 0
    failed = 0
    fixed_description = 0
    clash_check = [] of Tuple(String, Int64, String, Int64)
    Booking.query.by_zones(["zone-G5o6CPdNWUc"]).each do |booking|
      if booking.asset_id.starts_with? "area-F"
        # ID looks like: area-F.16.30-status
        puts "updating booking #{booking.id} for #{booking.asset_id}"
        parts = booking.asset_id.split('-')[1].split('.')
        level_id = parts[1]
        desk_id = parts[2]
        booking.asset_id = "desk-BR#{level_id.rjust(2,'0')}.#{desk_id.rjust(3,'0')}F"
        if description = booking.description
          booking.description = description.split("-")[0] + "-#{booking.asset_id}"
        end
        if booking.save
          success += 1
          clash_check << {booking.user_email, booking.booking_start, booking.asset_id, booking.booking_end}
        else
          failed += 1
        end
      elsif (description = booking.description) && description.includes?("-area-F")
        booking.description = description.split("-")[0] + "-#{booking.asset_id}"
        if booking.save
          fixed_description += 1
          success += 1
          clash_check << {booking.user_email, booking.booking_start, booking.asset_id, booking.booking_end}
        else
          failed += 1
        end
      end
    end
    puts "found #{success + failed + fixed_description} successfully updated #{success} bookings, fixed description on #{fixed_description} bookings"

    puts "checking for clashes..."
    puts "asset_id, user_email, booking_start, booking_end"
    clashes = 0
    clash_check.each do |(user_email, booking_start, asset_id, booking_end)|
      if Booking.query.where(
          "booking_start = :starting AND asset_id = :asset",
          starting: booking_start, asset: asset_id
        ).count > 1_i64
        clashes += 1
        puts "#{asset_id}, #{user_email}, #{booking_start}, #{booking_end}"
      end
    end
    puts "found #{clashes} clashes"

    exit 0
  end
end

# Load the routes
puts "Launching #{App::NAME} v#{App::VERSION}"

# Requiring config here ensures that the option parser runs before
# attempting to connect to databases etc.

server = ActionController::Server.new(port, host)

# (process_count < 1) == `System.cpu_count` but this is not always accurate
# Clustering using processes, there is no forking once crystal threads drop
server.cluster(process_count, "-w", "--workers") if process_count != 1

terminate = Proc(Signal, Nil).new do |signal|
  puts " > terminating gracefully"
  spawn { server.close }
  signal.ignore
end

# Detect ctr-c to shutdown gracefully
# Docker containers use the term signal
Signal::INT.trap &terminate
Signal::TERM.trap &terminate

# Allow signals to change the log level at run-time
logging = Proc(Signal, Nil).new do |signal|
  level = signal.usr1? ? Log::Severity::Debug : Log::Severity::Info
  puts " > Log level changed to #{level}"
  Log.builder.bind "#{App::NAME}.*", level, App::LOG_BACKEND
  signal.ignore
end

# Turn on DEBUG level logging `kill -s USR1 %PID`
# Default production log levels (INFO and above) `kill -s USR2 %PID`
Signal::USR1.trap &logging
Signal::USR2.trap &logging

# Start the server
server.run do
  puts "Listening on #{server.print_addresses}"
end

# Shutdown message
puts "#{App::NAME} leaps through the veldt\n"
