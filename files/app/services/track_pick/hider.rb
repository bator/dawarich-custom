# frozen_string_literal: true

# When a ride comes from another source (another user's GPS or the timetable line), the
# target's own points in that ride's time are hidden the way Dawarich hides GPS noise:
# anomaly = TRUE, track_id = NULL (Points::AnomalyFilter#flag_anomalies). Nothing is
# deleted. Every hidden id goes to state/hidden-<date>.jsonl, so track_pick:unhide[DATE]
# can put them back. Note: Points::AnomalyBackfillUserJob clears every anomaly flag of a
# user before it re-judges, which would bring these points back too.
#
# After the transaction (#rebuild): tile epoch bump, the day's tracks built again (#rebuild_tracks),
# stats of the month, achievements.
class TrackPick::Hider
  GTFS_TRACKER = 'track-pick-gtfs'

  def initialize(date, target_user = TrackPick::Config.target_user)
    @date = date
    @target = target_user
  end

  # windows: [[from, to], ...] epoch seconds; returns [[id, track_id, timestamp], ...]
  def hide(windows)
    return [] if windows.empty?

    scope = Point.where(user_id: @target.id).where('anomaly IS NOT TRUE')
                 .where('tracker_id IS DISTINCT FROM ?', GTFS_TRACKER)
    rel = windows.map { |from, to| scope.where(timestamp: from.to_i..to.to_i) }.reduce(:or)
    hidden = rel.pluck(:id, :track_id, :timestamp)
    return [] if hidden.empty?

    Point.where(id: hidden.map(&:first)).update_all('anomaly = TRUE, track_id = NULL, updated_at = NOW()')
    hidden
  end

  # after the commit: log the hidden ids, then let Dawarich rebuild what depends on them
  def rebuild(hidden:, inserted:)
    return if hidden.empty? && !inserted.positive?

    log(hidden) if hidden.any?
    from, to = TrackPick::Config.day_range(@date)
    Points::TileEpoch.bump_range(@target.id, from, to)
    month = Time.zone.at(from).in_time_zone(TrackPick::Config.zone)
    Stats::CalculatingJob.perform_later(@target.id, month.year, month.month)
    rebuild_tracks(from, to)
    Achievements::CheckJob.defer(@target.id, oldest_timestamp: from)
  rescue StandardError => e
    Rails.logger.error("[track_pick] rebuild after pick failed: #{e.class}: #{e.message}")
  end

  # puts back what hide wrote for the date; returns the number of points shown again
  def unhide
    ids = File.readlines(log_path).flat_map { |l| JSON.parse(l)['ids'] }.uniq
    return 0 if ids.empty?

    n = Point.where(id: ids, user_id: @target.id, anomaly: true).update_all(anomaly: false, updated_at: Time.current)
    File.rename(log_path, "#{log_path}.undone-#{Time.now.strftime('%Y%m%d-%H%M%S')}")
    from, to = TrackPick::Config.day_range(@date)
    Points::TileEpoch.bump_range(@target.id, from, to)
    rebuild_tracks(from, to)
    n
  rescue Errno::ENOENT
    0
  end

  def log_path
    File.join(TrackPick::Config::STATE_DIR, "hidden-#{@date.iso8601}.jsonl")
  end

  private

  # Every track of the day built again (Dawarich bulk mode: the day's tracks are deleted and
  # rebuilt from its points). Recalculating the old tracks kept a phone track across the hidden
  # ride, one straight line over it, and the copied / timetable points stayed without a track:
  # 2026-10-22, a 54.7 km line Székesfehérvár - Kelenföld on the map (Bator). start_at /
  # end_at must be times: the generator calls in_time_zone on them, and with epoch integers
  # the job failed silently (ParallelGeneratorJob rescues and only reports).
  def rebuild_tracks(from, to)
    Tracks::ParallelGeneratorJob.perform_later(@target.id, start_at: Time.zone.at(from), end_at: Time.zone.at(to),
                                                           mode: :bulk)
  end

  def log(hidden)
    FileUtils.mkdir_p(TrackPick::Config::STATE_DIR)
    File.open(log_path, 'a') do |f|
      f.puts(JSON.generate(time: Time.current.iso8601, user_id: @target.id, ids: hidden.map(&:first)))
    end
  end
end
