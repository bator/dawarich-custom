# frozen_string_literal: true

# Unit tests for the custom GTFS matcher and track_pick code. They run inside the Dawarich app
# (Rails loaded, autoload works) with `bin/rails runner`, but never write to the database.
# test/run.sh copies the repo's files/ tree to the box and loads the files listed below over
# the deployed ones first, so a change is tested before it is deployed.
require 'minitest/autorun'

OVERLAY = ENV.fetch('DC_TEST_OVERLAY', '/tmp/dc-test/files')
%w[
  app/services/gtfs/matching/window_detector.rb
  app/services/gtfs/matching/scorer.rb
  app/services/gtfs/matching/feed_set.rb
  app/services/gtfs/segment_matcher.rb
  app/services/gtfs/match_cases.rb
  app/services/track_pick/segments.rb
  app/services/track_pick/message.rb
  app/services/track_pick/discord_handler.rb
  app/services/track_pick/late_ride_line.rb
  app/services/gtfs/discord/client.rb
  app/services/gtfs/discord/config.rb
  app/jobs/gtfs/discord/notify_job.rb
  app/services/gtfs/walk_owners.rb
  app/serializers/api/transit_walk_leg_serializer.rb
].each do |rel|
  path = File.join(OVERLAY, rel)
  silence_warnings { load path } if File.exist?(path) # constant redefinition warnings only
end

module TestGeo
  M_PER_DEG_LAT = 111_195.0

  # a point `metres` north of (lon, lat)
  def north(lon, lat, metres) = [lon, lat + (metres / M_PER_DEG_LAT)]

  def mp(ts, lon = 19.0, lat = 47.5, id: ts)
    Gtfs::Matching::PointLoader::MatchPoint.new(id:, ts:, lon:, lat:, accuracy: 5.0, speed: nil)
  end
end
