# frozen_string_literal: true

# Summary of the shadow dry run (Gtfs::Walk::ShadowSnap) from log lines, for
# `gtfs:walk_shadow_report`. Reads `[GTFS walk shadow] key=value ...` lines
# (any prefix, e.g. journald's, is ignored) and persists nothing.
#
# A day is matched again on the following nights (MATCH_LOOKBACK_DAYS), so
# it is logged several times: only the latest run of each user-day counts
# (its `kind=day` line and the `kind=leg` lines with the same `run` id), so a
# leg that vanished in a later run is not counted (review A4).
#
# Also counts the live `[GTFS walk] ... NOT SAVED (reason)` lines (breaker
# open: outage or used-up budget; review K3) as user-days per reason: a day
# that failed on several nights counts once (review A-new-1); the raw line
# count is reported next to it. A user-day that failed on more than one run
# is listed as repeated (review H-2: a day that never fits into the time
# budget is lost once it leaves the lookback), and the `used_s` of the live
# lines is summarised (how close days come to GTFS_WALK_DAY_BUDGET_SECS).
class Gtfs::Walk::ShadowReport
  LINE = /\[GTFS walk shadow\] (?<fields>kind=.*)\z/
  NOT_SAVED = /\[GTFS walk\] user (?<user>\d+) (?<day>\d{4}-\d\d-\d\d)(?: DRY)?: .* NOT SAVED \((?<reason>[\w-]+)\)/
  LIVE_USED = /\[GTFS walk\] user \d+ (?<day>\d{4}-\d\d-\d\d)(?: DRY)?: .*\bused_s=(?<used>[\d.]+)/
  OUTCOMES = %w[valhalla mixed raw aborted].freeze

  def self.parse(line)
    match = LINE.match(line.to_s.chomp)
    return nil unless match

    match[:fields].scan(/(\w+)=(\S*)/).to_h { |k, v| [k, v == '-' ? nil : v] }
  end

  # days: only the last N days up to `today` (by the logged day)
  def initialize(lines, days: nil, today: Date.current)
    @runs = Hash.new { |h, k| h[k] = {} }
    @days = {}
    @errors = 0
    @not_saved = []
    @live_used = []
    from = days && (today - (days - 1))
    lines.each do |line|
      next if live_line(line.to_s, from)

      fields = self.class.parse(line)
      next unless fields
      next if from && fields['day'] && fields['day'] < from.to_s

      case fields['kind']
      when 'leg' then @runs[fields['run']][fields['leg']] = fields
      when 'day' then @days[[fields['user'], fields['day']]] = fields # the latest run wins
      when 'error' then @errors += 1
      end
    end
    @legs = @days.values.flat_map { |d| @runs.fetch(d['run'], {}).values }
  end

  def call
    legs = @legs
    not_saved_runs = @not_saved.tally
    {
      'days' => @days.keys.map(&:last).uniq.sort,
      'user_days' => @days.size,
      'skipped_user_days' => tally(@days.values.filter_map { |d| d['skipped'] }),
      'breaker_user_days' => tally(@days.values.filter_map { |d| d['breaker'] }),
      'not_run_legs' => @days.values.sum { |d| d['not_run'].to_i },
      'errors' => @errors,
      'live_not_saved' => @not_saved.uniq.map(&:last).tally.sort.to_h,
      'live_not_saved_user_days' => @not_saved.map { |u, d, _| [u, d] }.uniq.size,
      'live_not_saved_lines' => @not_saved.size,
      'live_not_saved_repeated' => not_saved_runs.select { |_, n| n > 1 }.sort
                                                 .map { |(u, d, r), n| "user #{u} #{d} #{r} x#{n}" },
      'live_used_s' => quantiles(@live_used),
      'legs' => legs.size,
      'outcomes' => OUTCOMES.index_with { |o| legs.count { |l| l['outcome'] == o } },
      'in_privacy_zone' => legs.count { |l| l['in_zone'] == '1' },
      'raw_km' => km(legs, 'raw_m'),
      'drawn_km' => km(legs, 'drawn_m'),
      'snapped_km' => km(snapped(legs), 'drawn_m'),
      'p95_m' => quantiles(snapped(legs).filter_map { |l| num(l['p95_m']) }),
      'rejection_reasons' => reasons(legs),
      'per_user' => per_user(legs)
    }
  end

  def to_s
    r = call
    return 'No [GTFS walk shadow] lines found.' if r['user_days'].zero? && r['live_not_saved'].empty?

    o = r['outcomes']
    [
      "GTFS walk shadow (legs scope=all would add): #{r['days'].first}..#{r['days'].last}, " \
      "#{r['days'].size} days, #{r['user_days']} user-days",
      "legs: #{r['legs']} (snapped #{o['valhalla']}, mixed #{o['mixed']}, raw #{o['raw']}, " \
      "aborted #{o['aborted']}), not run (budget/breaker): #{r['not_run_legs']}",
      "length: recorded #{r['raw_km']} km, drawn #{r['drawn_km']} km, of it snapped legs #{r['snapped_km']} km",
      "p95 distance of snapped legs (m): #{r['p95_m'].map { |k, v| "#{k}=#{v}" }.join(' ').presence || '-'}",
      "rejection reasons: #{line_of(r['rejection_reasons'])}",
      "in a privacy zone (would be deleted): #{r['in_privacy_zone']}",
      "skipped user-days: #{line_of(r['skipped_user_days'])}; shadow breaker: #{line_of(r['breaker_user_days'])}; " \
      "errors: #{r['errors']}",
      "live NOT SAVED (user-days per reason): #{line_of(r['live_not_saved'])} " \
      "(#{r['live_not_saved_user_days']} user-days, #{r['live_not_saved_lines']} lines); " \
      "repeated: #{r['live_not_saved_repeated'].join(', ').presence || '-'}",
      "live used_s per run: #{r['live_used_s'].map { |k, v| "#{k}=#{v}" }.join(' ').presence || '-'}",
      *r['per_user'].map do |user, u|
        "  user #{user}: legs=#{u['legs']} snapped=#{u['snapped']} raw=#{u['raw']} km=#{u['raw_km']}"
      end
    ].join("\n")
  end

  private

  # a live `[GTFS walk] user N day: ...` line (counted, true) or not (false)
  def live_line(line, from)
    live = NOT_SAVED.match(line)
    used = LIVE_USED.match(line)
    @not_saved << [live[:user], live[:day], live[:reason]] if live && !(from && live[:day] < from.to_s)
    @live_used << used[:used].to_f if used && !(from && used[:day] < from.to_s)
    !(live || used).nil?
  end

  def snapped(legs) = legs.select { |l| %w[valhalla mixed].include?(l['outcome']) }

  def tally(values) = values.tally.sort.to_h

  def line_of(hash) = hash.map { |k, v| "#{k} #{v}" }.join(', ').presence || '-'

  def num(value) = Float(value, exception: false)

  def km(legs, key) = (legs.sum { |l| num(l[key]).to_f } / 1000).round(1)

  def quantiles(values)
    return {} if values.empty?

    sorted = values.sort
    { 'p50' => sorted[(sorted.size - 1) / 2].round(1), 'p90' => sorted[((sorted.size - 1) * 0.9).floor].round(1),
      'max' => sorted.last.round(1) }
  end

  def reasons(legs)
    counts = Hash.new(0)
    legs.each do |l|
      l['reasons'].to_s.split(',').each do |pair|
        name, count = pair.split(':')
        counts[name.split('=').first] += count.to_i
      end
    end
    counts.sort_by { |k, v| [-v, k] }.to_h
  end

  def per_user(legs)
    legs.group_by { |l| l['user'] }.sort.to_h do |user, list|
      [user, { 'legs' => list.size, 'snapped' => snapped(list).size,
               'raw' => list.count { |l| l['outcome'] == 'raw' }, 'raw_km' => km(list, 'raw_m') }]
    end
  end
end
