# frozen_string_literal: true

# Test cases for the GTFS matcher on the live data, dry (rake
# gtfs:match_cases): matches the days again with Gtfs::SegmentMatcher and
# compares the result with what is known to be right. Nothing is saved.
#
# - Every reviewed ride is a case. A confirmed ride must be found again: a
#   match overlapping at least MIN_OVERLAP of its time. `trip` when it is the
#   same trip, `stops` when the same line, boarding and alighting stop, else
#   it is a failure (`other` names what was found instead, `missing` none).
# - A rejected ride must not come back the same (same line and stops over
#   its time): `back` is a failure, `gone` / `changed` pass.
# - The hand-written cases of config/gtfs_match_cases.yml (expect / forbid).
#
# A day whose points a track_pick pick hid (TrackPick::Hider, the hidden ids
# in its state log) is replayed as before the pick: in a transaction that is
# rolled back, those points are shown again and the timetable points the pick
# wrote are hidden. Otherwise the confirmed ride of a picked day could never
# be found from GPS.
class Gtfs::MatchCases
  MIN_OVERLAP = 0.5
  CASES_FILE = Rails.root.join('config/gtfs_match_cases.yml')
  # the case file's wall-clock times (a user's own setting may be UTC: user 7)
  CASE_ZONE = 'Europe/Budapest'

  Result = Struct.new(:case_id, :kind, :user_id, :date, :expected, :grade, :found, :pass, keyword_init: true)

  def initialize(days: 90, user_id: nil, reviews: true, logger: Rails.logger)
    @days = days
    @user_id = user_id
    @reviews = reviews
    @logger = logger
  end

  # => [Result, ...]
  def call
    results = []
    plan.each do |(user_id, date), cases|
      user = User.find_by(id: user_id)
      next unless user

      matches = match_day(user, date)
      cases.each { |c| results.concat(check(c, user, date, matches)) }
    end
    results
  end

  private

  # {[user_id, date] => [case, ...]}
  def plan
    out = Hash.new { |h, k| h[k] = [] }
    review_cases.each { |c| out[[c[:user_id], c[:date]]] << c } if @reviews
    file_cases.each { |c| out[[c[:user_id], c[:date]]] << c }
    out
  end

  def review_cases
    scope = TransitSegment.where(status: %i[confirmed rejected])
                          .where('started_at >= ?', @days.days.ago.to_i)
    scope = scope.where(user_id: @user_id) if @user_id
    scope.includes(:user).map do |s|
      zone = ActiveSupport::TimeZone[s.user.timezone_iana.to_s] || Time.zone
      { kind: s.status, id: "ride-#{s.id}", user_id: s.user_id, date: Time.zone.at(s.started_at).in_time_zone(zone).to_date,
        ride: s }
    end
  end

  def file_cases
    return [] unless File.exist?(CASES_FILE)

    Array(YAML.safe_load_file(CASES_FILE, permitted_classes: [Date])['cases']).filter_map do |c|
      next if @user_id && c['user_id'].to_i != @user_id.to_i

      { kind: 'file', id: c['id'], user_id: c['user_id'].to_i, date: Date.parse(c['date'].to_s),
        expect: Array(c['expect']), forbid: Array(c['forbid']) }
    end
  end

  def match_day(user, date)
    from, to = Gtfs::MatchDay.day_range(user, date)
    run = -> { Gtfs::SegmentMatcher.new(user).match(from, to).matches.map { |m| describe(m) } }
    hidden = hidden_ids(user, date)
    return run.call if hidden.empty?

    found = nil
    ActiveRecord::Base.transaction do
      Point.where(id: hidden, user_id: user.id).update_all(anomaly: false)
      Point.where(user_id: user.id, tracker_id: TrackPick::Hider::GTFS_TRACKER, timestamp: from...to)
           .update_all(anomaly: true)
      found = run.call
      raise ActiveRecord::Rollback
    end
    found
  end

  def hidden_ids(user, date)
    return [] unless defined?(TrackPick::Hider)

    path = TrackPick::Hider.new(date, user).log_path
    return [] unless File.exist?(path)

    File.readlines(path).map { |l| JSON.parse(l) }.select { |e| e['user_id'].to_i == user.id }
        .flat_map { |e| e['ids'] }.uniq
  rescue StandardError => e
    @logger.warn("[GTFS match cases] hidden ids #{date}: #{e.class}: #{e.message}")
    []
  end

  def describe(match)
    s = match.score
    { feed_id: s.candidate.feed.id, trip: s.candidate.trip_gtfs_id, line: s.profile.line_name.to_s,
      board: s.board&.name.to_s, alight: s.alight&.name.to_s, from: match.started_at.to_i, to: match.ended_at.to_i,
      confidence: match.confidence.round(2) }
  end

  def check(kase, user, date, matches)
    case kase[:kind]
    when 'confirmed' then [check_confirmed(kase, matches)]
    when 'rejected' then [check_rejected(kase, matches)]
    else check_file(kase, user, date, matches)
    end
  end

  def check_confirmed(kase, matches)
    r = kase[:ride]
    expected = ride_desc(r)
    hit = best_overlap(matches, r.started_at, r.ended_at)
    grade = if hit.nil? then 'missing'
            elsif hit[:feed_id] == r.feed_id && hit[:trip] == r.trip_gtfs_id then 'trip'
            elsif same_stops?(hit, expected) then 'stops'
            else 'other'
            end
    result(kase, expected, grade, hit, %w[trip stops].include?(grade))
  end

  def check_rejected(kase, matches)
    r = kase[:ride]
    expected = ride_desc(r)
    hit = best_overlap(matches, r.started_at, r.ended_at)
    grade = if hit.nil? then 'gone'
            elsif same_stops?(hit, expected) then 'back'
            else 'changed'
            end
    result(kase, expected, grade, hit, grade != 'back')
  end

  def check_file(kase, user, date, matches)
    zone = ActiveSupport::TimeZone[CASE_ZONE]
    at = ->(hhmm) { hhmm && zone.parse("#{date} #{hhmm}").to_i }
    expects = kase[:expect].map do |e|
      tol = e.fetch('tolerance_min', 10).to_i * 60
      want = { line: e['line'].to_s, board: e['board'].to_s, alight: e['alight'].to_s, from: at.(e['from']), to: at.(e['to']) }
      hit = matches.find do |m|
        same_stops?(m, want) && (want[:from].nil? || (m[:from] - want[:from]).abs <= tol) &&
          (want[:to].nil? || (m[:to] - want[:to]).abs <= tol)
      end
      near = hit || best_overlap(matches, want[:from] || 0, want[:to] || Float::INFINITY)
      result(kase, want, hit ? 'found' : 'missing', near, !hit.nil?, suffix: 'expect')
    end
    forbids = kase[:forbid].map do |f|
      want = { line: f['line'].to_s, board: f['board'].to_s, alight: f['alight'].to_s, from: at.(f['from']), to: at.(f['to']) }
      hit = matches.find do |m|
        same_stops?(m, want) && (want[:from].nil? || m[:to] > want[:from]) && (want[:to].nil? || m[:from] < want[:to])
      end
      result(kase, want, hit ? 'back' : 'absent', hit, hit.nil?, suffix: 'forbid')
    end
    expects + forbids
  end

  def result(kase, expected, grade, found, pass, suffix: nil)
    Result.new(case_id: [kase[:id], suffix].compact.join('/'), kind: kase[:kind], user_id: kase[:user_id],
               date: kase[:date], expected:, grade:, found:, pass:)
  end

  def ride_desc(ride)
    { line: ride.route_short_name.to_s, board: ride.boarding_stop_name.to_s, alight: ride.alighting_stop_name.to_s,
      from: ride.started_at.to_i, to: ride.ended_at.to_i }
  end

  def best_overlap(matches, from, to)
    span = [to - from, 1].max
    best = matches.max_by { |m| overlap(m, from, to) }
    best if best && overlap(best, from, to) >= MIN_OVERLAP * [span, m_span(best)].min
  end

  def overlap(match, from, to) = [[match[:to], to].min - [match[:from], from].max, 0].max

  def m_span(match) = [match[:to] - match[:from], 1].max

  def same_stops?(match, want)
    norm(match[:line]) == norm(want[:line]) && norm(match[:board]) == norm(want[:board]) &&
      norm(match[:alight]) == norm(want[:alight])
  end

  def norm(text) = text.to_s.unicode_normalize(:nfc).strip.downcase
end
