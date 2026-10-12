require "http/client"

# Loads the files PlaceOS records point at by url, such as level maps and space images:
# public urls, or rest-api uploads (`/api/v2/uploads/<id>/url`) that redirect to their storage.
module StaffApi::Upload
  MAX_REDIRECTS = 5

  IMAGE_EXTENSIONS = {
    ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".png" => "image/png", ".gif" => "image/gif",
    ".webp" => "image/webp", ".avif" => "image/avif", ".svg" => "image/svg+xml",
  }

  # `filename="x.png"` or `filename*=UTF-8''x.png` in a Content-Disposition header
  FILENAME = /filename\*?=(?:UTF-8\x27\x27)?\x22?([^\x22;]+)\x22?/i

  # the file's body, read up to the size limit
  record File, body : String, content_type : String?, truncated : Bool = false, disposition : String? = nil do
    def media_type : String?
      content_type.try { |type| type.split(';').first.strip.downcase }
    end
  end

  # The file's image media type, nil when it isn't an image. Storage often serves uploads as
  # `application/octet-stream` downloads, so then it's worked out from the bytes or file name
  def self.image_type(file : File, url : String) : String?
    type = file.media_type
    return type if type && type.starts_with?("image/")
    return unless type.nil? || type.ends_with?("octet-stream")
    sniff_image(file.body) ||
      extension_type(file.disposition.try(&.match(FILENAME)).try(&.[1])) ||
      extension_type(URI.parse(url).path)
  end

  protected def self.sniff_image(body : String) : String?
    bytes = body.to_slice
    if bytes.size >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
      "image/jpeg"
    elsif body.starts_with?("\x89PNG\r\n\x1A\n")
      "image/png"
    elsif body.starts_with?("GIF87a") || body.starts_with?("GIF89a")
      "image/gif"
    elsif body.starts_with?("RIFF") && body.byte_slice(8, 4) == "WEBP"
      "image/webp"
    elsif (head = body.byte_slice(0, 1024)).lstrip.starts_with?('<') && head.includes?("<svg")
      "image/svg+xml"
    end
  end

  protected def self.extension_type(name : String?) : String?
    name.try { |file| IMAGE_EXTENSIONS[::File.extname(file).downcase]? }
  end

  # the absolute url, relative urls are on the `origin`
  def self.resolve(url : String, origin : URI) : URI
    origin.resolve(url.strip)
  end

  # Fetches the file at `url`, reading at most `max_bytes` (`File#truncated` when there's more).
  #
  # Redirects are followed, but `credentials` are only ever sent to the origin's host, so an
  # upload that redirects to its storage never leaks the caller's token.
  def self.fetch(url : String, origin : URI, credentials : HTTP::Headers, accept : String = "*/*", max_bytes : Int32 = 20 * 1024 * 1024, label : String = "file") : File
    location = resolve(url, origin)

    (MAX_REDIRECTS + 1).times do
      unless location.scheme.in?("http", "https") && location.host.presence
        raise ::Error::BadUpstreamResponse.new("unsupported #{label} url #{location}")
      end

      headers = HTTP::Headers{"Accept" => accept}
      headers.merge!(credentials) if same_origin?(location, origin)

      result = HTTP::Client.new(location) do |client|
        client.connect_timeout = 5.seconds
        client.read_timeout = 20.seconds
        client.get(location.request_target, headers) do |response|
          if response.status.redirection? && (target = response.headers["Location"]?)
            location.resolve(target)
          elsif response.success?
            # streamed responses have a body_io, buffered ones (i.e. mocked) a body
            data = if io = response.body_io?
                     buffer = IO::Memory.new
                     IO.copy(io, buffer, max_bytes + 1)
                     buffer.to_s
                   else
                     response.body
                   end
            File.new(data.byte_slice(0, max_bytes), response.headers["Content-Type"]?, data.bytesize > max_bytes, response.headers["Content-Disposition"]?)
          else
            raise ::Error::BadUpstreamResponse.new("the #{label} #{location} responded with #{response.status_code}")
          end
        end
      end

      return result if result.is_a?(File)
      location = result
    end
    raise ::Error::BadUpstreamResponse.new("the #{label} #{location} redirected too many times")
  rescue error : IO::Error | OpenSSL::Error
    raise ::Error::BadUpstreamResponse.new("unable to load the #{label} #{url}: #{error.message}")
  end

  def self.same_origin?(location : URI, origin : URI) : Bool
    location.scheme == origin.scheme &&
      location.host.try(&.downcase) == origin.host.try(&.downcase) &&
      location.port == origin.port
  end
end
