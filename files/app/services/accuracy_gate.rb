# frozen_string_literal: true

# Points whose reported accuracy is worse than the user's
# `gps_accuracy_threshold` setting (metres) are hidden the way Dawarich hides
# GPS noise: anomaly = TRUE, track_id = NULL (Points::AnomalyFilter). Nothing
# is deleted. Dawarich 1.17.0 keeps the setting but no longer reads it, and
# fixes of a few hundred metres to a kilometre drew zigzags across the map
# (16 Pro, 2026-10-23: 327 of 7212 points of a week worse than 200 m; Bator).
#
# Every hidden id goes to STATE_DIR/<user_id>/<YYYY-MM-DD>.jsonl (the points'
# local day), so AccuracyGate.undo can put them back. Afterwards the days with
# hidden points get their tracks built again (Dawarich bulk mode, as
# TrackPick::Hider does), and the tile revisions follow the points' update.
#
# Since Dawarich 1.19.0 the upstream filter does this (gps_accuracy_filter_enabled,
# docs/atlas.md); AccuracyGateJob is no longer scheduled. Kept for undo and
# manual runs (lib/tasks/accuracy_gate.rake).
class AccuracyGate
  STATE_DIR = ENV.fetch('ACCURACY_GATE_STATE_DIR', '/opt/dawarich/accuracy-gate/state')
  DEFAULT_ZONE = 'Europe/Budapest'

  Result = Struct.new(:user_id, :threshold, :hidden, :days, keyword_init: true)

  # the user's threshold in metres, or nil when unset
  def self.threshold(user)
    value = (user.settings || {})['gps_accuracy_threshold'].to_i
    value.positive? ? value : nil
  end

  def self.users
    User.where("COALESCE(users.settings->>'gps_accuracy_threshold', '') ~ '^[0-9]+$'")
        .where("(users.settings->>'gps_accuracy_threshold')::int > 0")
  end

  # from_ts / to_ts: epoch seconds, nil for no limit
  def initialize(user, from_ts: nil, to_ts: nil)
    @user = user
    @from_ts = from_ts
    @to_ts = to_ts
    @threshold = self.class.threshold(user)
  end

  def scope
    return Point.none unless @threshold

    rel = Point.where(user_id: @user.id).where('points.anomaly IS NOT TRUE')
               .where('points.accuracy > ?', @threshold)
    rel = rel.where(timestamp: @from_ts..) if @from_ts
    rel = rel.where(timestamp: ..@to_ts) if @to_ts
    rel
  end

  # => Result; dry_run: only counts
  def call(dry_run: false)
    rows = scope.pluck(:id, :timestamp)
    days = rows.map { |_, ts| local_day(ts) }.uniq.sort
    unless dry_run || rows.empty?
      Point.where(id: rows.map(&:first)).update_all('anomaly = TRUE, track_id = NULL, updated_at = NOW()')
      log(rows)
      rebuild_tracks(days)
    end
    Result.new(user_id: @user.id, threshold: @threshold, hidden: rows.size, days:)
  end

  # Shows again what the gate hid on the local days from..to (Dates);
  # => number of points shown again
  def self.undo(user, from:, to:)
    dir = File.join(STATE_DIR, user.id.to_s)
    files = (from..to).map { |d| File.join(dir, "#{d.iso8601}.jsonl") }.select { |f| File.exist?(f) }
    ids = files.flat_map { |f| File.readlines(f).flat_map { |l| JSON.parse(l)['ids'] } }.uniq
    return 0 if ids.empty?

    n = Point.where(id: ids, user_id: user.id, anomaly: true).update_all(anomaly: false, updated_at: Time.current)
    stamp = Time.now.strftime('%Y%m%d-%H%M%S')
    files.each { |f| File.rename(f, "#{f}.undone-#{stamp}") }
    new(user).send(:rebuild_tracks, (from..to).to_a)
    n
  end

  private

  def zone
    @zone ||= ActiveSupport::TimeZone[@user.timezone_iana.to_s] || ActiveSupport::TimeZone[DEFAULT_ZONE]
  end

  def local_day(timestamp) = Time.zone.at(timestamp).in_time_zone(zone).to_date

  def log(rows)
    dir = File.join(STATE_DIR, @user.id.to_s)
    FileUtils.mkdir_p(dir)
    rows.group_by { |_, ts| local_day(ts) }.each do |day, day_rows|
      File.open(File.join(dir, "#{day.iso8601}.jsonl"), 'a') do |f|
        f.puts(JSON.generate(time: Time.current.iso8601, threshold: @threshold, ids: day_rows.map(&:first)))
      end
    end
  end

  # one bulk rebuild from the first to the last day (start_at / end_at must be
  # times: the generator calls in_time_zone on them, see TrackPick::Hider)
  def rebuild_tracks(days)
    return if days.empty?

    from = zone.local(days.first.year, days.first.month, days.first.day)
    to = zone.local(days.last.year, days.last.month, days.last.day) + 1.day
    TrackModeCorrections.new(@user).capture! # hand-set modes are written back after (Gtfs::TrackModesJob)
    Tracks::ParallelGeneratorJob.perform_later(@user.id, start_at: from, end_at: to, mode: :bulk)
  end
end
