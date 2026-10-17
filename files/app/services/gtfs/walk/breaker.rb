# frozen_string_literal: true

# Circuit breaker and time budget for one user-day of walk snapping (review
# M1). Opens on the first "service unavailable" answer or when the day's
# budget is used up; after that no more requests are sent and the day is not
# written (the next run tries again), so an outage never replaces snapped
# legs with raw ones.
class Gtfs::Walk::Breaker
  attr_reader :reason, :budget

  def initialize(budget_secs: Gtfs::Walk::Config::DAY_BUDGET_SECS,
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @budget = budget_secs.to_f
    @clock = clock
    @started = clock.call
    @reason = nil
  end

  def open?
    trip!('time_budget') if @reason.nil? && @clock.call - @started > @budget
    !@reason.nil?
  end

  # seconds left of the budget (the HTTP client never waits longer)
  def remaining = @budget - used

  # seconds since the breaker was created (logged by DaySnap, review H-2)
  def used = @clock.call - @started

  def trip!(reason)
    @reason = reason if @reason.nil? # the first reason is kept
  end
end
