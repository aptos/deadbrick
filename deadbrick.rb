#!/usr/bin/env ruby
require 'webrick'
include WEBrick

class WEBrick::HTTPRequest
  def read_request_line(socket)
    @request_line = read_line(socket, 1024) if socket
    died?
    if @request_line.bytesize >= 1024 and @request_line[-1, 1] != LF
      raise HTTPStatus::RequestURITooLarge
    end
    @request_time = Time.now
    raise HTTPStatus::EOFError unless @request_line
    if /^(\S+)\s+(\S++)(?:\s+HTTP\/(\d+\.\d+))?\r?\n/mo =~ @request_line
      @request_method = $1
      @unparsed_uri   = $2
      @http_version   = HTTPVersion.new($3 ? $3 : "0.9")
    else
      rl = @request_line.sub(/\x0d?\x0a\z/o, '')
      raise HTTPStatus::BadRequest, "bad Request-Line `#{rl}'."
    end
  end

  # check fault matchers and set dead
  # $died_time is checked in send_response
  def died?
    if fault
      puts "Died!"
      $dead = true
      $died_time = Time.now.to_i
    end
    $dead
  end
  
  # Fault matchers go here
  def fault
    @request_line or return false
    # overflow
    @request_line.bytesize >= 1024 and return true
    # format
    @request_line =~ /65535d/ and return true
    # delimiters
    @request_line =~ /!HTTP/ and return true
  end
end

class WEBrick::HTTPResponse
  alias_method :orig_send_response, :send_response
  
  # Check if system is still dead before sending any response
  # While system is recovering (dead) 
  def send_response(socket)
    if is_dead?
      puts "Died at [#{Time.at $died_time}] - so not responding for (#{$recover_time - @countdown}) more seconds"
      exit
    elsif $rl and $rl.limit?
      puts "Rate limit exceeded!"
      exit
    else
      orig_send_response(socket)
    end
  end

  # Service remains dead for $recover_time seconds
  def is_dead?
    @countdown = Time.now.to_i - $died_time
    $dead = false if @countdown > $recover_time
    $dead
  end
end

class RateLimit
  def initialize(params)
    @rate = params[:rate].to_f
    @bucket = @window = params[:window].to_i
    @per_second = @rate
    puts "rate limit to #{@rate} per second within a window of #{@window} seconds"
    @last_drip = Time.now.to_f
  end

  def limit?
    now = Time.now.to_f
    @bucket -= 1
    @bucket += (now - @last_drip)*@per_second
    @bucket = case
    when @bucket > @window
      @window
    when @bucket < 1
      0
    else
      @bucket
    end
    @last_drip = now
    puts "bucket depth: #{@bucket}"
    @bucket < 1
  end
  
end

dir = Dir::pwd
port = 80

puts "URL: http://#{Socket.gethostname}:#{port}"

server = HTTPServer.new(
  :Port            => port,
  :DocumentRoot    => dir
  )

trap("INT"){ server.shutdown }

server.mount_proc '/' do |req, res|
  res.body = 'Goodbye cruel world!'
end

$dead = false
$died_time = 0
$recover_time = 15
$rl = RateLimit.new({rate:5000, window:5})

server.start

