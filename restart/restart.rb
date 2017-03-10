#!/usr/bin/env ruby

require 'bundler/setup'
require 'socket'
require 'active_support/values/time_zone'
require 'active_support/core_ext/time'
require 'active_support/core_ext/numeric/time'

UDP_RECV_TIMEOUT = 3

WINDOW_START = '01:00' # 1am
WINDOW_DURATION = 4.hours
WINDOW_TIMEZONE = ActiveSupport::TimeZone['Eastern Time (US & Canada)']
MAX_SLEEP = 3600
STAMP_FILE = 'restart-stamp'

EMPTY_TIME = 600
QUERY_INTERVAL = 10

def nearby_windows
  current = Time.parse(WINDOW_START)
  [-1, 0, 1].map do |offset|
    start = current + offset.days
    stop  = start + WINDOW_DURATION
    start..stop
  end
end

def current_or_next_window(now = Time.now)
  nearby_windows.find { |w| w.max >= now }
end

def sleep_and_exit(sleep_for)
  sleep_for = MAX_SLEEP if sleep_for > MAX_SLEEP
  puts "Sleeping for #{sleep_for} seconds."
  sleep(sleep_for)
  exit(0)
end

Settings = Struct.new(
  :server_name, :map, :game_directory,
  :game_description, :appID, :number_players,
  :maximum_players, :number_bots, :dedicated,
  :os, :password, :secure, :game_version,
)

class QueryTimeout < StandardError; end

def query_server(host, port)
  sock = UDPSocket.open
  sock.send("\377\377\377\377TSource Engine Query\0", 0, host, port)
  resp = if select([sock], nil, nil, UDP_RECV_TIMEOUT)
    sock.recvfrom(65536)
  end

  raise QueryTimeout if resp.nil?
  data = resp[0].unpack('@6Z*Z*Z*Z*vcccaaccZ*')
  return Settings.new(*data)
end

def server_is_empty(host, port)
  query = query_server(host, port)
  puts "Number of players: #{query.number_players} / #{query.maximum_players}"
  return query.number_players == 0
end

def main(host, port = 27015)
  now = WINDOW_TIMEZONE.now
  window = current_or_next_window(now)
  unless window.include?(now)
    wait = (window.min - now).ceil
    puts "Maintenance window is at #{window.min}, in #{wait} seconds."
    sleep_and_exit(wait)
  end

  puts "Inside maintenance window, proceeding."

  last_restart = nil
  begin
    last_restart = File.stat(STAMP_FILE).mtime
  rescue Errno::ENOENT
    # continue
  end

  if last_restart.nil?
    puts "Server has never been restarted."
  else
    ago = (now - last_restart).floor
    puts "Last restart was at #{last_restart}, #{ago} seconds ago."
    if window.include?(last_restart)
      puts "Server has already been restarted during the current window."
      sleep_and_exit(window.max - now)
    end
  end

  unless server_is_empty(host, port)
    puts "Server is not empty."
    sleep_and_exit(60)
  end

  puts "Waiting for server to be empty for #{EMPTY_TIME} seconds."
  target_time = Time.now + EMPTY_TIME
  until Time.now >= target_time do
    sleep(QUERY_INTERVAL)
    unless server_is_empty(host, port)
      puts "Server is no longer empty."
      sleep_and_exit(60)
    end
  end

  puts "Proceeding with restart."
  FileUtils.touch(STAMP_FILE)
  system(*%w(sudo sv restart kf2))
end

main(*ARGV)
