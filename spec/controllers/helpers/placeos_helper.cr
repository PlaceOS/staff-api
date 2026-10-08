require "redis"

# Captures the signals staff-api publishes to redis
module SignalSpy
  extend self

  record Signal, channel : String, payload : JSON::Any

  @@signals = [] of Signal
  @@lock = Mutex.new
  @@started = false

  # Subscribes to every placeos channel for the remainder of the suite
  def start : Nil
    return if @@started
    @@started = true

    ready = Channel(Nil).new
    spawn do
      Redis.new(url: App::REDIS_URL).psubscribe("placeos/*") do |subscription|
        subscription.psubscribe { |_pattern, _count| ready.send(nil) }
        subscription.pmessage do |_pattern, channel, message|
          @@lock.synchronize { @@signals << Signal.new(channel, JSON.parse(message)) }
        end
      end
    end

    select
    when ready.receive
    when timeout(5.seconds)
      raise "timed out subscribing to redis at #{App::REDIS_URL}"
    end
  end

  def clear : Nil
    @@lock.synchronize { @@signals.clear }
  end

  def signals : Array(Signal)
    @@lock.synchronize { @@signals.dup }
  end

  # Payloads of the signals published to the channel so far, without waiting
  def payloads(channel : String) : Array(JSON::Any)
    signals.select(&.channel.==(channel)).map(&.payload)
  end

  # Publishes a signal as if from another source
  def publish(channel : String, payload) : Nil
    redis = Redis.new(url: App::REDIS_URL)
    redis.publish(channel, payload.to_json)
  ensure
    redis.try(&.close)
  end

  # Signals published to the channel, waiting for at least `count` to arrive
  def received(channel : String, count : Int32 = 1, wait : Time::Span = 2.seconds) : Array(Signal)
    received(channel, count, wait) { true }
  end

  # Signals published to the channel whose payload matches the block,
  # waiting for at least `count` to arrive
  def received(channel : String, count : Int32 = 1, wait : Time::Span = 2.seconds, & : JSON::Any -> Bool) : Array(Signal)
    deadline = Time.instant + wait
    loop do
      matching = signals.select { |signal| signal.channel == channel && yield(signal.payload) }
      return matching if matching.size >= count || Time.instant >= deadline
      sleep 10.milliseconds
    end
  end
end

Spec.before_suite { SignalSpy.start }
Spec.before_each { SignalSpy.clear }

# ControlSystem rows standing in for the systems PlaceOS manages
module SystemsHelper
  extend self

  FIXTURES = "./spec/fixtures/placeos"

  # Upserts the systems described by a fixture file, i.e. `systems.json` or `systemJ.json`
  # `zones` replaces the fixture's zones, so the systems are found by a zone search
  def load_fixture(file : String, zones : Array(String)? = nil) : Array(PlaceOS::Model::ControlSystem)
    json = JSON.parse(File.read(File.join(FIXTURES, file)))
    (json.as_a? || [json]).map { |details| upsert(details, zones) }
  end

  # Creates a system with the provided id, replacing any system with the same id or name
  def system(
    id : String,
    email : String? = nil,
    zones : Array(String) = [] of String,
    name : String = id,
    capacity : Int32 = 0,
    features : Array(String) = [] of String,
    bookable : Bool = true,
  ) : PlaceOS::Model::ControlSystem
    PlaceOS::Model::ControlSystem.find?(id).try(&.delete)
    PlaceOS::Model::ControlSystem.where(name: name).to_a.each(&.delete)

    system = PlaceOS::Model::Generator.control_system
    system.id = id
    system.name = name
    system.email = email.try { |address| PlaceOS::Model::Email.new(address) }
    system.zones = zones
    system.capacity = capacity
    system.features = Set.new(features)
    system.bookable = bookable
    system.save!
  end

  private def upsert(details : JSON::Any, zones : Array(String)? = nil) : PlaceOS::Model::ControlSystem
    system(
      id: details["id"].as_s,
      email: details["email"]?.try(&.as_s?),
      zones: zones || details["zones"]?.try(&.as_a.map(&.as_s)) || [] of String,
      name: details["name"]?.try(&.as_s?) || details["id"].as_s,
      capacity: details["capacity"]?.try(&.as_i?) || 0,
      features: details["features"]?.try(&.as_a.map(&.as_s)) || [] of String,
      bookable: details["bookable"]?.try(&.as_bool?) != false,
    )
  end
end
