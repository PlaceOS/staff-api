require "./application"
require "placeos-models/control_system"

class Rooms < Application
  base "/api/staff/v1/rooms"
  
  # Always considered bookable regardless of actual status
  ALWAYS_BOOKABLE = ["nyo-convergence_center@mckinsey.com", "nyz-conversion_center@mckinsey.com"]
  
  # GET /api/staff/v1/rooms
  # Returns list of rooms with optional filtering
  @[AC::Route::GET("/")]
  def index : Array(JSON::Any)
    # Extract query parameters
    zone_ids = query_params["zone_ids"]?.try(&.split(","))
    building_id = query_params["building_id"]?
    level_id = query_params["level_id"]?
    capacity = query_params["capacity"]?.try(&.to_i)
    capacity_max = query_params["capacity_max"]?.try(&.to_i)
    bookable = query_params["bookable"]? == "true"
    features = query_params["features"]?.try(&.split(","))
    
    # Optional availability checking parameters
    available_from = query_params["available_from"]?.try(&.to_i64)
    available_to = query_params["available_to"]?.try(&.to_i64)
    
    # Build the query
    query = PlaceOS::Model::ControlSystem.where(bookable: true) if bookable
    query ||= PlaceOS::Model::ControlSystem.all
    
    # Filter by zones
    zones_to_filter = [] of String
    zones_to_filter << building_id if building_id
    zones_to_filter << level_id if level_id
    zone_ids.try { |ids| zones_to_filter.concat(ids) }
    
    # Get all systems and filter in memory
    systems = query.to_a
    
    # Filter by zones if any provided
    unless zones_to_filter.empty?
      systems = systems.select do |sys|
        (sys.zones & zones_to_filter).any?
      end
    end
    
    # Filter by capacity
    if capacity
      systems = systems.select { |sys| sys.capacity >= capacity }
    end
    
    if capacity_max
      systems = systems.select { |sys| sys.capacity <= capacity_max }
    end
    
    # Filter by features
    if features && !features.empty?
      feature_set = features.to_set
      systems = systems.select do |sys|
        feature_set.all? { |f| sys.features.includes?(f) }
      end
    end
    
    # Check availability if time range provided
    if available_from && available_to
      systems = check_availability(systems, available_from, available_to)
    end
    
    # Transform to JSON response format
    rooms = systems.map do |room|
      build_room_response(room, available_from, available_to)
    end
    
    rooms
  end
  
  # GET /api/staff/v1/rooms/:id
  # Get a specific room by ID or email
  @[AC::Route::GET("/:id")]
  def show(id : String) : JSON::Any
    # Handle legacy confroom_ prefix
    if id.downcase.starts_with?("confroom_")
      id = id[9..]
    end
    
    # Try to find by ID first, then by email
    room = begin
      PlaceOS::Model::ControlSystem.find(id)
    rescue
      # If not found by ID, try by email
      PlaceOS::Model::ControlSystem.where(email: id).first?
    end
    
    raise Error::NotFound.new("Room not found") unless room
    
    build_room_response(room, nil, nil)
  end
  
  private def build_room_response(room : PlaceOS::Model::ControlSystem, available_from : Int64?, available_to : Int64?) : JSON::Any
    response = JSON.build do |json|
      json.object do
        json.field "id", room.id
        json.field "name", room.name
        json.field "display_name", room.display_name
        json.field "description", room.description
        json.field "email", room.email
        json.field "capacity", room.capacity
        json.field "features", room.features.to_a
        json.field "bookable", room.bookable
        json.field "zones", room.zones
        json.field "map_id", room.map_id
        json.field "images", room.images
        json.field "code", room.code
        json.field "type", room.type
        json.field "approval", room.approval
        
        # Add settings object
        json.field "settings" do
          json.object do
            # Check if room is in always bookable list
            if room.email && ALWAYS_BOOKABLE.includes?(room.email.to_s.downcase)
              json.field "available", true
              json.field "available_until", available_to if available_to
            elsif available_from && available_to
              # For regular rooms, check actual availability
              available = check_room_availability(room, available_from, available_to)
              json.field "available", available[:available]
              json.field "available_until", available[:available_until]
              json.field "bookings", available[:bookings]
              json.field "bookings_count", available[:bookings].size
            end
          end
        end
      end
    end
    
    JSON.parse(response)
  end
  
  private def check_availability(systems : Array(PlaceOS::Model::ControlSystem), available_from : Int64, available_to : Int64) : Array(PlaceOS::Model::ControlSystem)
    # This is a simplified availability check
    # In the full implementation, this would check against bookings
    systems
  end
  
  private def check_room_availability(room : PlaceOS::Model::ControlSystem, available_from : Int64, available_to : Int64) : NamedTuple(available: Bool, available_until: Int64, bookings: Array(JSON::Any))
    # Check if room is in always bookable list
    if room.email && ALWAYS_BOOKABLE.includes?(room.email.to_s.downcase)
      return {available: true, available_until: available_to, bookings: [] of JSON::Any}
    end
    
    # Get bookings for this room in the specified time range
    bookings = [] of JSON::Any
    
    # Query bookings for this room
    if room.email
      room_bookings = PlaceOS::Model::Booking
        .where("user_email = ? OR asset_id = ?", [room.email.to_s, room.id.to_s])
        .where("booking_start < ? AND booking_end > ? AND deleted = ?", [available_to, available_from, false])
        .to_a
      
      # Check if any booking conflicts with the requested time
      has_conflict = room_bookings.any? do |booking|
        # Skip cancelled bookings
        next if booking.rejected || booking.deleted
        
        # Check for time overlap
        booking_overlaps?(booking.booking_start, booking.booking_end, available_from, available_to)
      end
      
      # Build bookings array for response
      bookings = room_bookings.map do |booking|
        JSON.parse({
          id: booking.id,
          start: booking.booking_start,
          end: booking.booking_end,
          title: booking.title,
          user_name: booking.user_name,
          user_email: booking.user_email,
          checked_in: booking.checked_in
        }.to_json)
      end
      
      # Calculate available_until
      available_until = if has_conflict
        # Find the earliest conflicting booking
        earliest_conflict = room_bookings
          .select { |b| !b.rejected && !b.deleted && b.booking_start >= available_from }
          .min_by?(&.booking_start)
        
        earliest_conflict.try(&.booking_start) || available_from
      else
        available_to
      end
      
      return {available: !has_conflict, available_until: available_until, bookings: bookings}
    end
    
    # Default to available if no email
    {available: true, available_until: available_to, bookings: [] of JSON::Any}
  end
  
  private def booking_overlaps?(booking_start : Int64, booking_end : Int64, request_start : Int64, request_end : Int64) : Bool
    # Check if booking overlaps with requested time period
    (request_start < booking_end) && (booking_start < request_end)
  end
end