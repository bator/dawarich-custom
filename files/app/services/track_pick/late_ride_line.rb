# frozen_string_literal: true

# A ride matched (or confirmed) after the day's track pick was decided never got a choice:
# 2026-11-12, ride 181 (IC 849) appeared on 11-14, after the 11-13 06:00 decision, and the map
# kept the phone's broken track (1-4 km fixes hidden, 07:47-08:17 missing). Bator: the line of
# such a ride should go in by itself.
#
# For a decided day, every ride of the target that is confirmed (or matched at AUTO_ACCEPT or
# better), whose timetable line is usable, which has no timetable points yet, and where the
# target's own good fixes cover less than MIN_COVERAGE of the ride, gets its timetable line
# written (TrackPick::GtfsPoints) and the target's own points of that time hidden
# (TrackPick::Hider: nothing deleted, track_pick:unhide[DATE] puts them back). A well covered
# ride keeps the phone's own track.
class TrackPick::LateRideLine
  MIN_COVERAGE = TrackPick::Segments::GOOD_COVERAGE
  COVER_STEP = TrackPick::Segments::COVER_STEP

  Result = Struct.new(:segment_id, :coverage, :inserted, :hidden, keyword_init: true)

  def initialize(date, target_user = TrackPick::Config.target_user)
    @date = date
    @target = target_user
  end

  # => [Result, ...] for the rides that got (dry run: would get) their line
  def call(dry_run: false)
    decision = TrackPick::Config.decision(@date) or return []
    return [] if decision['choice'].to_s == SKIPPED # "Kihagyás": the day is left as it is

    candidates.reject { |seg| offered?(seg, decision) }.filter_map do |seg|
      coverage = coverage_of(seg)
      next if coverage >= MIN_COVERAGE

      gtfs = TrackPick::GtfsPoints.new(@date, seg, @target)
      next unless gtfs.usable?
      next Result.new(segment_id: seg.id, coverage:, inserted: gtfs.call(dry_run: true), hidden: 0) if dry_run

      write(seg, gtfs, coverage)
    end
  end

  SKIPPED = 'Kihagyás'

  private

  # A ride the day's message already offered was decided on, even when Bator kept his own
  # points: it is not "late" (review 2026-11-15). With a saved segment list (since
  # 2026-11-08) a ride overlapping an offered :ride segment was offered; for older messages
  # only a ride created after the decision counts as late.
  def offered?(seg, decision)
    saved = TrackPick::Segments.load(@date)
    if saved
      saved.any? { |s| s['kind'] == 'ride' && s['from'].to_i < seg.ended_at && s['to'].to_i > seg.started_at }
    else
      decided_at = Time.zone.parse(decision['time'].to_s)
      decided_at.nil? || seg.created_at <= decided_at
    end
  end

  def candidates
    from, to = TrackPick::Config.day_range(@date)
    TransitSegment.where(user_id: @target.id, started_at: from...to).where.not(status: :rejected).order(:started_at)
                  .select { |s| s.confirmed? || s.confidence.to_f >= Gtfs::Config::AUTO_ACCEPT }
                  .reject { |s| timetable_points?(s) }
  end

  def timetable_points?(seg)
    Point.where(user_id: @target.id, tracker_id: TrackPick::GtfsPoints::TRACKER_ID,
                timestamp: seg.started_at..seg.ended_at).exists?
  end

  # share of the ride covered by the target's good fixes (not flagged, accuracy at most
  # MAX_ACCURACY_M; GPS copied by a pick counts, a timetable line does not) at most COVER_STEP apart
  def coverage_of(seg)
    duration = seg.ended_at - seg.started_at
    return 1.0 unless duration.positive?

    times = Point.where(user_id: @target.id, timestamp: seg.started_at..seg.ended_at)
                 .where('anomaly IS NOT TRUE AND (accuracy IS NULL OR accuracy <= ?)', Gtfs::Config::MAX_ACCURACY_M)
                 .where('tracker_id IS DISTINCT FROM ?', TrackPick::GtfsPoints::TRACKER_ID)
                 .order(:timestamp).pluck(:timestamp)
    covered = times.each_cons(2).sum { |a, b| b - a <= COVER_STEP ? b - a : 0 }
    (covered.to_f / duration).clamp(0.0, 1.0)
  end

  def write(seg, gtfs, coverage)
    hider = TrackPick::Hider.new(@date, @target)
    hidden = []
    inserted = ActiveRecord::Base.transaction do
      hidden = hider.hide([[seg.started_at, seg.ended_at]])
      gtfs.call
    end
    hider.rebuild(hidden:, inserted:)
    Rails.logger.info("[track_pick] late ride #{seg.id} (#{@date}, #{seg.route_short_name}): coverage " \
                      "#{(coverage * 100).round} %, #{inserted} timetable points, #{hidden.size} own points hidden")
    Result.new(segment_id: seg.id, coverage:, inserted:, hidden: hidden.size)
  end
end
