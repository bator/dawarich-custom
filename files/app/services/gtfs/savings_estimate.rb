# frozen_string_literal: true

# Rough estimate for /transit/savings: CO2 and money of the counted rides
# compared with making the same distance by car. Everything here is an
# assumption, shown on the page, and each value can be overridden with an
# environment variable (e.g. in /opt/dawarich/gtfs.env):
#   TRANSIT_CO2_CAR_G_KM, TRANSIT_CO2_<MODE>_G_PKM (MODE: BUS TRAM METRO RAIL SUBURBAN FERRY OTHER),
#   TRANSIT_CAR_FT_KM, TRANSIT_TICKET_FT, TRANSIT_PASS_FT, TRANSIT_TREE_KG_YEAR
# The car distance is the ride distance (the road would usually be longer).
class Gtfs::SavingsEstimate
  # Average emission factors in g CO2e: per vehicle-km for the car, per
  # passenger-km for public transport (rounded averages of the kind national
  # inventories publish; not specific to Hungarian vehicles or electricity).
  DEFAULT_CO2_G_PKM = { 'bus' => 100, 'tram' => 30, 'metro' => 30, 'rail' => 35, 'suburban' => 35, 'ferry' => 115, 'other' => 80 }.freeze
  DEFAULT_CAR_G_KM = 170
  # Fuel only (about 7 l/100 km), no parking, insurance or wear.
  DEFAULT_CAR_FT_KM = 45
  # BKK single ticket and Budapest monthly pass, 2024 prices.
  DEFAULT_TICKET_FT = 450
  DEFAULT_PASS_FT = 8950
  PASS_DAYS = 30
  # CO2 a grown tree takes up in a year (common rough figure; Quambio uses
  # "100 km by car ≈ one tree for a year").
  DEFAULT_TREE_KG_YEAR = 22

  def self.env_number(name, default)
    Float(ENV[name].to_s, exception: false)&.then { |v| v.positive? ? v : nil } || default
  end

  def initialize(rides, days:, since: nil, zone: Time.zone)
    @rides = rides
    @days = days
    @zone = zone
    @from = zone.at((since || days.days.ago).to_i).to_date
  end

  def car_g_km = self.class.env_number('TRANSIT_CO2_CAR_G_KM', DEFAULT_CAR_G_KM)
  def car_ft_km = self.class.env_number('TRANSIT_CAR_FT_KM', DEFAULT_CAR_FT_KM)
  def ticket_ft = self.class.env_number('TRANSIT_TICKET_FT', DEFAULT_TICKET_FT)
  def pass_ft = self.class.env_number('TRANSIT_PASS_FT', DEFAULT_PASS_FT)
  def tree_kg_year = self.class.env_number('TRANSIT_TREE_KG_YEAR', DEFAULT_TREE_KG_YEAR)

  def co2_g_pkm(mode)
    self.class.env_number("TRANSIT_CO2_#{mode.upcase}_G_PKM", DEFAULT_CO2_G_PKM.fetch(mode, DEFAULT_CO2_G_PKM['other']))
  end

  def km = @rides.sum { |s| s.distance_m.to_f } / 1000.0
  def rides_count = @rides.size

  # [[mode, km, transit_kg, car_kg], ...] by km desc
  def by_mode
    @rides.group_by(&:mode).map do |mode, list|
      km = list.sum { |s| s.distance_m.to_f } / 1000.0
      [mode, km, km * co2_g_pkm(mode) / 1000.0, km * car_g_km / 1000.0]
    end.sort_by { |row| -row[1] }
  end

  def transit_kg = by_mode.sum { |row| row[2] }
  def car_kg = km * car_g_km / 1000.0
  def saved_kg = car_kg - transit_kg

  def car_cost_ft = km * car_ft_km
  def tickets_ft = rides_count * ticket_ft
  def passes = (@days / PASS_DAYS.to_f).ceil
  def passes_ft = passes * pass_ft
  def cheaper_option = tickets_ft <= passes_ft ? :tickets : :pass
  def transit_cost_ft = [tickets_ft, passes_ft].min
  def saved_ft = car_cost_ft - transit_cost_ft

  # Trees that would take up the saved CO2 in a year.
  def trees = saved_kg / tree_kg_year

  # Car kilometres that would emit the saved CO2.
  def car_km_equivalent = saved_kg * 1000 / car_g_km

  # Rides per PASS_DAYS from which the pass is cheaper than single tickets,
  # and the user's own pace (rides per PASS_DAYS in the period).
  def break_even_rides = (pass_ft / ticket_ft).ceil
  def rides_per_pass_period = rides_count * PASS_DAYS / @days.to_f

  # Cumulative cost per day of the period, oldest first:
  # [[Date, car_ft, tickets_ft, pass_ft], ...]. The pass is bought on the
  # first day and again every PASS_DAYS, `passes` times in all.
  def cumulative
    by_day = @rides.group_by { |s| @zone.at(s.started_at).to_date }
    car = 0.0
    tickets = 0.0
    (@from..@zone.today).each_with_index.map do |date, index|
      list = by_day.fetch(date, [])
      car += list.sum { |s| s.distance_m.to_f } / 1000.0 * car_ft_km
      tickets += list.size * ticket_ft
      [date, car, tickets, ([index / PASS_DAYS, passes - 1].min + 1) * pass_ft]
    end
  end

  # [[month (Date), saved_kg, km], ...] oldest first
  def by_month
    @rides.group_by { |s| @zone.at(s.started_at).to_date.beginning_of_month }.sort.map do |month, list|
      km = list.sum { |s| s.distance_m.to_f } / 1000.0
      transit = list.sum { |s| s.distance_m.to_f / 1000.0 * co2_g_pkm(s.mode) } / 1000.0
      [month, km * car_g_km / 1000.0 - transit, km]
    end
  end
end
