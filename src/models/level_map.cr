require "http/client"
require "xml"

# A level map SVG, indexing the centre of every element with an id so we can rank
# things, such as desks, by how close they are to each other.
#
# Ported from the `Nearby` helper of the PlaceOS LLM drivers.
struct StaffApi::LevelMap
  record Point, x : Float64, y : Float64 do
    def distance_to(other : Point) : Float64
      dx = other.x - x
      dy = other.y - y
      Math.sqrt(dx * dx + dy * dy)
    end
  end

  # 2D affine transform, as used by the SVG `transform` attribute:
  #
  #   | a c e |
  #   | b d f |
  #   | 0 0 1 |
  record Matrix, a : Float64, b : Float64, c : Float64, d : Float64, e : Float64, f : Float64 do
    def self.identity : Matrix
      new(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    end

    # self * other (other is applied first)
    def *(other : Matrix) : Matrix
      Matrix.new(
        a * other.a + c * other.b,
        b * other.a + d * other.b,
        a * other.c + c * other.d,
        b * other.c + d * other.d,
        a * other.e + c * other.f + e,
        b * other.e + d * other.f + f
      )
    end

    def apply(point : Point) : Point
      Point.new(
        a * point.x + c * point.y + e,
        b * point.x + d * point.y + f
      )
    end
  end

  # Accumulates the axis aligned bounding box of the points it is fed
  class BoundsBuilder
    @min_x : Float64 = 0.0
    @min_y : Float64 = 0.0
    @max_x : Float64 = 0.0
    @max_y : Float64 = 0.0
    @empty : Bool = true

    def add(point : Point) : Nil
      if @empty
        @min_x = @max_x = point.x
        @min_y = @max_y = point.y
        @empty = false
        return
      end

      @min_x = Math.min(@min_x, point.x)
      @min_y = Math.min(@min_y, point.y)
      @max_x = Math.max(@max_x, point.x)
      @max_y = Math.max(@max_y, point.y)
    end

    def center : Point?
      return nil if @empty
      Point.new((@min_x + @max_x) / 2.0, (@min_y + @max_y) / 2.0)
    end
  end

  NUMBER_PATTERN    = /[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?/
  TOKEN_PATTERN     = /[A-Za-z]|[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?/
  TRANSFORM_PATTERN = /([a-zA-Z]+)\s*\(([^)]*)\)/

  # id => centre point of the element
  getter centers : Hash(String, Point)

  def initialize(svg : String)
    @centers = {} of String => Point
    build_index svg
  end

  # the distance between the centres of two elements, nil if either isn't on the map
  def distance(from_id : String, to_id : String) : Float64?
    return nil unless from = centers[from_id]?
    return nil unless to = centers[to_id]?
    from.distance_to(to)
  end

  # Loading
  # =========================

  MAX_REDIRECTS = 5
  CACHE_TTL     = 10.minutes
  CACHE_SIZE    = 64

  @@cache = {} of String => Tuple(LevelMap, Time::Instant)
  @@cache_lock = Mutex.new

  # Fetches and parses the map at `url`, caching it for `CACHE_TTL`.
  #
  # A relative url resolves against `origin`, the authority's domain. Redirects are
  # followed, but `credentials` are only ever sent to the origin's host, so a rest-api
  # upload (which redirects to its storage) never leaks the caller's token.
  def self.load(url : String, origin : URI, credentials : HTTP::Headers) : LevelMap
    location = origin.resolve(url.strip)
    key = location.to_s

    if cached = @@cache_lock.synchronize { @@cache[key]? }
      map, loaded_at = cached
      return map if Time.instant - loaded_at < CACHE_TTL
    end

    map = new(fetch(location, origin, credentials))
    @@cache_lock.synchronize do
      @@cache.delete(key)
      # hashes keep their insertion order, so the first entry is the oldest
      @@cache.shift if @@cache.size >= CACHE_SIZE
      @@cache[key] = {map, Time.instant}
    end
    map
  rescue error : XML::Error
    raise ::Error::BadUpstreamResponse.new("the level map #{url} isn't a valid SVG: #{error.message}")
  end

  # :nodoc: specs reset the cache between examples
  def self.clear_cache : Nil
    @@cache_lock.synchronize { @@cache.clear }
  end

  protected def self.fetch(location : URI, origin : URI, credentials : HTTP::Headers) : String
    (MAX_REDIRECTS + 1).times do
      unless location.scheme.in?("http", "https") && location.host.presence
        raise ::Error::BadUpstreamResponse.new("unsupported level map url #{location}")
      end

      headers = HTTP::Headers{"Accept" => "image/svg+xml, */*;q=0.5"}
      headers.merge!(credentials) if same_origin?(location, origin)

      response = HTTP::Client.new(location) do |client|
        client.connect_timeout = 5.seconds
        client.read_timeout = 20.seconds
        client.get(location.request_target, headers)
      end

      if response.status.redirection? && (target = response.headers["Location"]?)
        location = location.resolve(target)
        next
      end
      return response.body if response.success?
      raise ::Error::BadUpstreamResponse.new("the level map #{location} responded with #{response.status_code}")
    end
    raise ::Error::BadUpstreamResponse.new("the level map #{location} redirected too many times")
  rescue error : IO::Error | OpenSSL::Error
    raise ::Error::BadUpstreamResponse.new("unable to load the level map #{location}: #{error.message}")
  end

  protected def self.same_origin?(location : URI, origin : URI) : Bool
    location.scheme == origin.scheme &&
      location.host.try(&.downcase) == origin.host.try(&.downcase) &&
      location.port == origin.port
  end

  # SVG parsing
  # =========================

  protected def build_index(svg : String) : Nil
    document = XML.parse(svg)

    document.xpath_nodes("//*[@id]").each do |node|
      id = node["id"]?
      next if id.nil? || id.empty?
      next if @centers.has_key?(id)

      builder = BoundsBuilder.new
      add_geometry(builder, node, accumulated_matrix(node))

      if center = builder.center
        @centers[id] = center
      end
    end
  end

  # combines the transforms of this node and all of its ancestors
  protected def accumulated_matrix(node : XML::Node) : Matrix
    matrix = Matrix.identity
    chain = [] of XML::Node

    current = node
    while current && current.element?
      chain << current
      current = current.parent
    end

    # outermost first, so parent transforms are applied before child ones
    chain.reverse_each do |element|
      if transform = element["transform"]?
        matrix = matrix * parse_transform(transform)
      end
    end

    matrix
  end

  protected def parse_transform(value : String) : Matrix
    matrix = Matrix.identity

    value.scan(TRANSFORM_PATTERN) do |match|
      args = number_tokens(match[2])

      operation = case match[1]
                  when "matrix"
                    next if args.size < 6
                    Matrix.new(args[0], args[1], args[2], args[3], args[4], args[5])
                  when "translate"
                    next if args.empty?
                    Matrix.new(1.0, 0.0, 0.0, 1.0, args[0], args[1]? || 0.0)
                  when "scale"
                    next if args.empty?
                    Matrix.new(args[0], 0.0, 0.0, args[1]? || args[0], 0.0, 0.0)
                  when "rotate"
                    next if args.empty?
                    radians = args[0] * Math::PI / 180.0
                    cos = Math.cos(radians)
                    sin = Math.sin(radians)
                    rotation = Matrix.new(cos, sin, -sin, cos, 0.0, 0.0)

                    if (cx = args[1]?) && (cy = args[2]?)
                      Matrix.new(1.0, 0.0, 0.0, 1.0, cx, cy) *
                        rotation *
                        Matrix.new(1.0, 0.0, 0.0, 1.0, -cx, -cy)
                    else
                      rotation
                    end
                  when "skewX"
                    next if args.empty?
                    Matrix.new(1.0, 0.0, Math.tan(args[0] * Math::PI / 180.0), 1.0, 0.0, 0.0)
                  when "skewY"
                    next if args.empty?
                    Matrix.new(1.0, Math.tan(args[0] * Math::PI / 180.0), 0.0, 1.0, 0.0, 0.0)
                  else
                    next
                  end

      matrix = matrix * operation
    end

    matrix
  end

  protected def add_geometry(builder : BoundsBuilder, node : XML::Node, matrix : Matrix) : Nil
    case node.name
    when "path"
      if data = node["d"]?
        add_path(builder, data, matrix)
      end
    when "rect"
      x = float_attribute(node, "x")
      y = float_attribute(node, "y")
      width = float_attribute(node, "width")
      height = float_attribute(node, "height")

      builder.add matrix.apply(Point.new(x, y))
      builder.add matrix.apply(Point.new(x + width, y))
      builder.add matrix.apply(Point.new(x + width, y + height))
      builder.add matrix.apply(Point.new(x, y + height))
    when "circle", "ellipse"
      cx = float_attribute(node, "cx")
      cy = float_attribute(node, "cy")
      radius = float_attribute(node, "r")
      rx = node["rx"]?.try(&.to_f64?) || radius
      ry = node["ry"]?.try(&.to_f64?) || radius

      builder.add matrix.apply(Point.new(cx - rx, cy - ry))
      builder.add matrix.apply(Point.new(cx + rx, cy - ry))
      builder.add matrix.apply(Point.new(cx + rx, cy + ry))
      builder.add matrix.apply(Point.new(cx - rx, cy + ry))
    when "line"
      builder.add matrix.apply(Point.new(float_attribute(node, "x1"), float_attribute(node, "y1")))
      builder.add matrix.apply(Point.new(float_attribute(node, "x2"), float_attribute(node, "y2")))
    when "polygon", "polyline"
      if points = node["points"]?
        values = number_tokens(points)
        index = 0
        while index + 1 < values.size
          builder.add matrix.apply(Point.new(values[index], values[index + 1]))
          index += 2
        end
      end
    else
      # groups and non geometric elements: fall through to the children below
    end

    # a group is bounded by everything it contains
    node.children.each do |child|
      next unless child.element?
      child_matrix = if transform = child["transform"]?
                       matrix * parse_transform(transform)
                     else
                       matrix
                     end
      add_geometry(builder, child, child_matrix)
    end
  end

  # Walks an SVG path, feeding the bounding box builder.
  #
  # Elliptical arcs are approximated by their endpoints. Maps only use them for the
  # rounded corners of furniture, where the error is a fraction of the corner radius
  # and cancels out across the shape, so the centre is unaffected.
  protected def add_path(builder : BoundsBuilder, path : String, matrix : Matrix) : Nil
    tokens = path_tokens(path)

    current = Point.new(0.0, 0.0)
    subpath_start = current
    command = '\0'
    index = 0

    add = ->(point : Point) { builder.add matrix.apply(point) }

    while index < tokens.size
      token = tokens[index]

      if command_token?(token)
        command = token[0]
        index += 1

        if command == 'Z' || command == 'z'
          current = subpath_start
          next
        end
      elsif command == '\0'
        # a path that starts with a number is malformed, ignore it
        return
      end

      relative = command.lowercase?

      case command
      when 'M', 'm'
        break unless point = read_point(tokens, index, current, relative)
        index += 2

        current = subpath_start = point
        add.call point

        # subsequent coordinate pairs are implicit line commands
        command = relative ? 'l' : 'L'
      when 'L', 'l'
        break unless point = read_point(tokens, index, current, relative)
        index += 2

        add.call current
        add.call point
        current = point
      when 'H', 'h'
        break unless x = number_at(tokens, index)
        index += 1

        point = Point.new(relative ? current.x + x : x, current.y)
        add.call current
        add.call point
        current = point
      when 'V', 'v'
        break unless y = number_at(tokens, index)
        index += 1

        point = Point.new(current.x, relative ? current.y + y : y)
        add.call current
        add.call point
        current = point
      when 'C', 'c'
        break unless control_1 = read_point(tokens, index, current, relative)
        break unless control_2 = read_point(tokens, index + 2, current, relative)
        break unless endpoint = read_point(tokens, index + 4, current, relative)
        index += 6

        add_cubic(builder, matrix, current, control_1, control_2, endpoint)
        current = endpoint
      when 'S', 's', 'Q', 'q'
        # smooth cubic and quadratic: 2 coordinate pairs, the control point
        # only ever pulls the curve within the hull of its endpoints
        break unless control = read_point(tokens, index, current, relative)
        break unless endpoint = read_point(tokens, index + 2, current, relative)
        index += 4

        add.call current
        add.call control
        add.call endpoint
        current = endpoint
      when 'T', 't'
        break unless endpoint = read_point(tokens, index, current, relative)
        index += 2

        add.call current
        add.call endpoint
        current = endpoint
      when 'A', 'a'
        # rx ry x-axis-rotation large-arc-flag sweep-flag x y
        break unless (0..4).all? { |offset| number_at(tokens, index + offset) }
        break unless endpoint = read_point(tokens, index + 5, current, relative)
        index += 7

        add.call current
        add.call endpoint
        current = endpoint
      else
        # unknown command, we can't reliably resume parsing
        return
      end
    end
  end

  protected def add_cubic(builder : BoundsBuilder, matrix : Matrix, p0 : Point, p1 : Point, p2 : Point, p3 : Point) : Nil
    # the transform is affine, so transforming the control points first means
    # the extrema we solve for are the extrema of the rendered curve
    p0 = matrix.apply p0
    p1 = matrix.apply p1
    p2 = matrix.apply p2
    p3 = matrix.apply p3

    builder.add p0
    builder.add p3

    (cubic_extrema(p0.x, p1.x, p2.x, p3.x) + cubic_extrema(p0.y, p1.y, p2.y, p3.y)).each do |t|
      builder.add cubic_point(p0, p1, p2, p3, t)
    end
  end

  protected def cubic_point(p0 : Point, p1 : Point, p2 : Point, p3 : Point, t : Float64) : Point
    inverse = 1.0 - t

    a = inverse * inverse * inverse
    b = 3.0 * inverse * inverse * t
    c = 3.0 * inverse * t * t
    d = t * t * t

    Point.new(
      a * p0.x + b * p1.x + c * p2.x + d * p3.x,
      a * p0.y + b * p1.y + c * p2.y + d * p3.y
    )
  end

  # solves B'(t) = 0 for the turning points that fall within the segment
  protected def cubic_extrema(p0 : Float64, p1 : Float64, p2 : Float64, p3 : Float64) : Array(Float64)
    roots = [] of Float64

    a = 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3)
    b = 2.0 * (3.0 * p0 - 6.0 * p1 + 3.0 * p2)
    c = -3.0 * p0 + 3.0 * p1

    epsilon = 1e-12

    if a.abs < epsilon
      unless b.abs < epsilon
        linear = -c / b
        roots << linear if linear > 0.0 && linear < 1.0
      end
      return roots
    end

    discriminant = b * b - 4.0 * a * c
    return roots if discriminant < 0.0

    root = Math.sqrt(discriminant)
    [(-b + root) / (2.0 * a), (-b - root) / (2.0 * a)].each do |t|
      roots << t if t > 0.0 && t < 1.0
    end

    roots
  end

  protected def read_point(tokens : Array(String), index : Int32, origin : Point, relative : Bool) : Point?
    return nil unless x = number_at(tokens, index)
    return nil unless y = number_at(tokens, index + 1)

    relative ? Point.new(origin.x + x, origin.y + y) : Point.new(x, y)
  end

  protected def number_at(tokens : Array(String), index : Int32) : Float64?
    token = tokens[index]?
    return nil if token.nil? || command_token?(token)
    token.to_f64?
  end

  protected def command_token?(token : String) : Bool
    token.size == 1 && token[0].ascii_letter?
  end

  protected def path_tokens(path : String) : Array(String)
    tokens = [] of String
    path.scan(TOKEN_PATTERN) { |match| tokens << match[0] }
    tokens
  end

  protected def number_tokens(value : String) : Array(Float64)
    numbers = [] of Float64
    value.scan(NUMBER_PATTERN) { |match| numbers << match[0].to_f64 }
    numbers
  end

  protected def float_attribute(node : XML::Node, name : String, default : Float64 = 0.0) : Float64
    node[name]?.try(&.to_f64?) || default
  end
end
