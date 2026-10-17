# frozen_string_literal: true

# Parses GTFS "HH:MM:SS" times into seconds since the start of the service
# day. Hours may exceed 23 (e.g. "25:10:00" = 90_600). Never use Time for this.
module Gtfs::TimeParser
  PATTERN = /\A\s*(\d{1,3}):([0-5]\d):([0-5]\d)\s*\z/

  class InvalidTime < StandardError; end

  module_function

  # Returns Integer seconds, nil for a blank value, raises InvalidTime otherwise.
  def parse(value)
    return nil if value.nil? || value.strip.empty?

    match = PATTERN.match(value)
    raise InvalidTime, "invalid GTFS time: #{value.inspect}" unless match

    (match[1].to_i * 3600) + (match[2].to_i * 60) + match[3].to_i
  end

  def format(secs)
    return nil if secs.nil?

    Kernel.format('%<h>02d:%<m>02d:%<s>02d', h: secs / 3600, m: (secs % 3600) / 60, s: secs % 60)
  end
end
