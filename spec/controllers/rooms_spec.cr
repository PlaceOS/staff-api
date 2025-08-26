require "../spec_helper"
require "./helpers/booking_helper"

ROOMS_BASE = Rooms.base_route

# Helper method to create a test room
def create_test_room(
  name : String = "Test Room #{Random.new.rand(1000)}",
  email : String? = "room-#{Random.new.rand(1000)}@example.com",
  capacity : Int32 = 10,
  bookable : Bool = true,
  zones : Array(String) = ["zone-building-1", "zone-level-1"],
  features : Set(String) = Set{"projector", "whiteboard"}
)
  PlaceOS::Model::ControlSystem.create!(
    name: name,
    email: email ? PlaceOS::Model::Email.new(email) : nil,
    capacity: capacity,
    bookable: bookable,
    zones: zones,
    features: features,
    display_name: "#{name} Display",
    description: "Test room description",
    code: "RM#{Random.new.rand(100)}",
    type: "meeting_room",
    map_id: "map_#{Random.new.rand(100)}",
    images: ["https://example.com/room1.jpg", "https://example.com/room2.jpg"],
    approval: false
  )
end

describe Rooms do
  Spec.before_each {
    PlaceOS::Model::ControlSystem.clear
    Booking.clear
    Attendee.truncate
    Guest.truncate
  }

  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "#index" do
    it "should return a list of rooms" do
      # Create test rooms
      room1 = create_test_room(
        name: "Conference Room A",
        email: "conf-a@example.com",
        capacity: 20,
        zones: ["zone-building-1", "zone-level-2"]
      )
      
      room2 = create_test_room(
        name: "Conference Room B",
        email: "conf-b@example.com",
        capacity: 8,
        zones: ["zone-building-1", "zone-level-3"]
      )

      room3 = create_test_room(
        name: "Conference Room C",
        email: "conf-c@example.com",
        capacity: 15,
        bookable: false,
        zones: ["zone-building-2", "zone-level-1"]
      )

      # Test basic listing
      response = client.get(ROOMS_BASE, headers: headers)
      response.status_code.should eq(200)
      
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(3)
      
      # Verify room structure
      first_room = rooms.first
      first_room["id"].as_s.should_not be_nil
      first_room["name"].as_s.should_not be_nil
      first_room["email"].as_s?.should_not be_nil
      first_room["capacity"].as_i.should be > 0
      first_room["bookable"].as_bool.should_not be_nil
      first_room["zones"].as_a.should_not be_empty
      first_room["features"].as_a.should_not be_nil
    end

    it "should filter rooms by zone_ids" do
      room1 = create_test_room(zones: ["zone-1", "zone-2"])
      room2 = create_test_room(zones: ["zone-2", "zone-3"])
      room3 = create_test_room(zones: ["zone-4", "zone-5"])

      # Filter by single zone
      response = client.get("#{ROOMS_BASE}?zone_ids=zone-1", headers: headers)
      response.status_code.should eq(200)
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(1)
      rooms.first["id"].should eq(room1.id)

      # Filter by multiple zones
      response = client.get("#{ROOMS_BASE}?zone_ids=zone-2,zone-3", headers: headers)
      response.status_code.should eq(200)
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(2)
      room_ids = rooms.map { |r| r["id"].as_s }
      room_ids.should contain(room1.id)
      room_ids.should contain(room2.id)
    end

    it "should filter rooms by capacity" do
      room1 = create_test_room(capacity: 5)
      room2 = create_test_room(capacity: 10)
      room3 = create_test_room(capacity: 20)

      # Filter by minimum capacity
      response = client.get("#{ROOMS_BASE}?capacity=10", headers: headers)
      response.status_code.should eq(200)
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(2)
      
      room_capacities = rooms.map { |r| r["capacity"].as_i }
      room_capacities.each { |c| c.should be >= 10 }
    end

    it "should filter rooms by capacity range" do
      room1 = create_test_room(capacity: 5)
      room2 = create_test_room(capacity: 10)
      room3 = create_test_room(capacity: 15)
      room4 = create_test_room(capacity: 25)

      # Filter by capacity range
      response = client.get("#{ROOMS_BASE}?capacity=8&capacity_max=20", headers: headers)
      response.status_code.should eq(200)
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(2)
      
      room_capacities = rooms.map { |r| r["capacity"].as_i }
      room_capacities.should contain(10)
      room_capacities.should contain(15)
    end

    it "should filter rooms by bookable status" do
      room1 = create_test_room(bookable: true)
      room2 = create_test_room(bookable: true)
      room3 = create_test_room(bookable: false)

      # Filter bookable rooms only
      response = client.get("#{ROOMS_BASE}?bookable=true", headers: headers)
      response.status_code.should eq(200)
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(2)
      
      rooms.each { |r| r["bookable"].as_bool.should be_true }
    end

    it "should filter rooms by features" do
      room1 = create_test_room(features: Set{"projector", "whiteboard", "video"})
      room2 = create_test_room(features: Set{"projector", "phone"})
      room3 = create_test_room(features: Set{"whiteboard"})

      # Filter by single feature
      response = client.get("#{ROOMS_BASE}?features=projector", headers: headers)
      response.status_code.should eq(200)
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(2)

      # Filter by multiple features (rooms must have all)
      response = client.get("#{ROOMS_BASE}?features=projector,whiteboard", headers: headers)
      response.status_code.should eq(200)
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(1)
      rooms.first["id"].should eq(room1.id)
    end

    it "should return a list of rooms along with a flag to show whether the room is available based on the available_from and available_to params" do
      tenant = get_tenant
      
      # Create test rooms
      room1 = create_test_room(email: "available-room@example.com")
      room2 = create_test_room(email: "booked-room@example.com")
      room3 = create_test_room(email: nil) # Room without email

      # Create a booking for room2 that will conflict with our search period
      booking_start = 30.minutes.from_now.to_unix
      booking_end = 90.minutes.from_now.to_unix
      
      BookingsHelper.create_booking(
        tenant_id: tenant.id.not_nil!,
        booking_start: booking_start,
        booking_end: booking_end,
        asset_id: room2.id.not_nil!
      ).tap do |booking|
        booking.user_email = PlaceOS::Model::Email.new(room2.email.not_nil!.to_s)
        booking.asset_id = room2.id.not_nil!
        booking.save!
      end

      # Check availability for a time period that overlaps with the booking
      available_from = 60.minutes.from_now.to_unix
      available_to = 120.minutes.from_now.to_unix
      
      response = client.get("#{ROOMS_BASE}?available_from=#{available_from}&available_to=#{available_to}", headers: headers)
      response.status_code.should eq(200)
      
      rooms = JSON.parse(response.body).as_a
      rooms.size.should eq(3)
      
      # Find each room in the response
      available_room = rooms.find { |r| r["id"] == room1.id }
      booked_room = rooms.find { |r| r["id"] == room2.id }
      no_email_room = rooms.find { |r| r["id"] == room3.id }
      
      # Room1 should be available
      available_room.should_not be_nil
      available_room.not_nil!["settings"]["available"].as_bool.should be_true
      available_room.not_nil!["settings"]["available_until"].as_i64.should eq(available_to)
      
      # Room2 should not be available due to booking
      booked_room.should_not be_nil
      booked_room.not_nil!["settings"]["available"].as_bool.should be_false
      
      # Room3 (no email) should be available by default
      no_email_room.should_not be_nil
      no_email_room.not_nil!["settings"]["available"].as_bool.should be_true
    end

    it "should return a list of rooms along with the bookings in those rooms that fall inside the passed in available_from and available_to params" do
      tenant = get_tenant
      
      # Create test rooms
      room1 = create_test_room(email: "room1@example.com")
      room2 = create_test_room(email: "room2@example.com")

      # Create bookings for the rooms
      # Booking that overlaps with search period
      booking1_start = 30.minutes.from_now.to_unix
      booking1_end = 90.minutes.from_now.to_unix
      booking1 = BookingsHelper.create_booking(
        tenant_id: tenant.id.not_nil!,
        booking_start: booking1_start,
        booking_end: booking1_end,
        asset_id: room1.id.not_nil!
      ).tap do |b|
        b.user_email = PlaceOS::Model::Email.new(room1.email.not_nil!.to_s)
        b.title = "Team Meeting"
        b.user_name = "John Doe"
        b.save!
      end

      # Booking that doesn't overlap with search period
      booking2_start = 3.hours.from_now.to_unix
      booking2_end = 4.hours.from_now.to_unix
      booking2 = BookingsHelper.create_booking(
        tenant_id: tenant.id.not_nil!,
        booking_start: booking2_start,
        booking_end: booking2_end,
        asset_id: room1.id.not_nil!
      ).tap do |b|
        b.user_email = PlaceOS::Model::Email.new(room1.email.not_nil!.to_s)
        b.title = "Later Meeting"
        b.save!
      end

      # Another booking for room2
      booking3_start = 45.minutes.from_now.to_unix
      booking3_end = 75.minutes.from_now.to_unix
      booking3 = BookingsHelper.create_booking(
        tenant_id: tenant.id.not_nil!,
        booking_start: booking3_start,
        booking_end: booking3_end,
        asset_id: room2.id.not_nil!
      ).tap do |b|
        b.user_email = PlaceOS::Model::Email.new(room2.email.not_nil!.to_s)
        b.title = "Client Presentation"
        b.user_name = "Jane Smith"
        b.checked_in = true
        b.save!
      end

      # Check availability for a time period
      available_from = 15.minutes.from_now.to_unix
      available_to = 2.hours.from_now.to_unix
      
      response = client.get("#{ROOMS_BASE}?available_from=#{available_from}&available_to=#{available_to}", headers: headers)
      response.status_code.should eq(200)
      
      rooms = JSON.parse(response.body).as_a
      
      # Find room1 in response
      room1_response = rooms.find { |r| r["id"] == room1.id }
      room1_response.should_not be_nil
      
      # Check bookings for room1
      room1_bookings = room1_response.not_nil!["settings"]["bookings"].as_a
      room1_bookings.size.should eq(2) # Both bookings fall within search range
      
      # Verify booking details
      booking_titles = room1_bookings.map { |b| b["title"]?.try(&.as_s) }.compact
      booking_titles.should contain("Team Meeting")
      
      # Check bookings count
      room1_response.not_nil!["settings"]["bookings_count"].as_i.should eq(2)
      
      # Find room2 in response
      room2_response = rooms.find { |r| r["id"] == room2.id }
      room2_response.should_not be_nil
      
      # Check bookings for room2
      room2_bookings = room2_response.not_nil!["settings"]["bookings"].as_a
      room2_bookings.size.should eq(1)
      
      # Verify checked_in status is included
      room2_booking = room2_bookings.first
      room2_booking["checked_in"].as_bool.should be_true
      room2_booking["user_name"].as_s.should eq("Jane Smith")
    end

    it "should handle always bookable rooms (convergence centers)" do
      # Create a convergence center room
      convergence_room = create_test_room(
        email: "nyo-convergence_center@mckinsey.com",
        capacity: 100
      )
      
      # Create another convergence center
      other_convergence = create_test_room(
        email: "nyz-conversion_center@mckinsey.com",
        capacity: 80
      )
      
      # Create a regular room
      regular_room = create_test_room(email: "regular@example.com")

      tenant = get_tenant
      
      # Create bookings for all rooms
      booking_start = 30.minutes.from_now.to_unix
      booking_end = 90.minutes.from_now.to_unix
      
      [convergence_room, other_convergence, regular_room].each do |room|
        BookingsHelper.create_booking(
          tenant_id: tenant.id.not_nil!,
          booking_start: booking_start,
          booking_end: booking_end,
          asset_id: room.id.not_nil!
        ).tap do |b|
          b.user_email = PlaceOS::Model::Email.new(room.email.not_nil!.to_s)
          b.save!
        end
      end

      # Check availability during the booked period
      available_from = 45.minutes.from_now.to_unix
      available_to = 75.minutes.from_now.to_unix
      
      response = client.get("#{ROOMS_BASE}?available_from=#{available_from}&available_to=#{available_to}", headers: headers)
      response.status_code.should eq(200)
      
      rooms = JSON.parse(response.body).as_a
      
      # Convergence centers should always be available
      conv_room = rooms.find { |r| r["email"] == "nyo-convergence_center@mckinsey.com" }
      conv_room.should_not be_nil
      conv_room.not_nil!["settings"]["available"].as_bool.should be_true
      conv_room.not_nil!["settings"]["available_until"].as_i64.should eq(available_to)
      
      other_conv = rooms.find { |r| r["email"] == "nyz-conversion_center@mckinsey.com" }
      other_conv.should_not be_nil
      other_conv.not_nil!["settings"]["available"].as_bool.should be_true
      
      # Regular room should not be available
      reg_room = rooms.find { |r| r["email"] == "regular@example.com" }
      reg_room.should_not be_nil
      reg_room.not_nil!["settings"]["available"].as_bool.should be_false
    end
  end

  describe "#show" do
    it "should return a specific room by ID" do
      room = create_test_room(
        name: "Executive Board Room",
        email: "exec-board@example.com",
        capacity: 30
      )

      response = client.get("#{ROOMS_BASE}/#{room.id}", headers: headers)
      response.status_code.should eq(200)
      
      room_data = JSON.parse(response.body)
      room_data["id"].should eq(room.id)
      room_data["name"].should eq("Executive Board Room")
      room_data["email"].should eq("exec-board@example.com")
      room_data["capacity"].should eq(30)
    end

    it "should return a specific room by email" do
      room = create_test_room(
        name: "Training Room",
        email: "training@example.com",
        capacity: 50
      )

      response = client.get("#{ROOMS_BASE}/training@example.com", headers: headers)
      response.status_code.should eq(200)
      
      room_data = JSON.parse(response.body)
      room_data["id"].should eq(room.id)
      room_data["email"].should eq("training@example.com")
    end

    it "should handle legacy confroom_ prefix" do
      room = create_test_room(
        name: "Conference Room",
        email: "conf@example.com"
      )

      # Try with confroom_ prefix
      response = client.get("#{ROOMS_BASE}/confroom_#{room.id}", headers: headers)
      response.status_code.should eq(200)
      
      room_data = JSON.parse(response.body)
      room_data["id"].should eq(room.id)
    end

    it "should return 404 for non-existent room" do
      response = client.get("#{ROOMS_BASE}/non-existent-room", headers: headers)
      response.status_code.should eq(404)
    end
  end
end