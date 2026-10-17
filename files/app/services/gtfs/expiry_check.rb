# frozen_string_literal: true

# Lists expired / soon-expiring feeds (spec 7.9) and notifies admins once per
# feed and validity end date.
class Gtfs::ExpiryCheck
  Entry = Struct.new(:feed, :state, :valid_until, keyword_init: true)

  def self.call(today: Date.current)
    Gtfs::Feed.where.not(valid_until: nil).order(:key).filter_map do |feed|
      if feed.expired?(on: today)
        Entry.new(feed:, state: :expired, valid_until: feed.valid_until)
      elsif feed.expiring_soon?(on: today)
        Entry.new(feed:, state: :expiring, valid_until: feed.valid_until)
      end
    end
  end

  def self.notify_admins!(today: Date.current)
    entries = call(today:).select { |e| e.feed.enabled? }
    return entries if entries.empty?

    content = entries.map do |e|
      "#{e.feed.name} (#{e.feed.key}): #{e.state == :expired ? 'expired on' : 'expires on'} #{e.valid_until}"
    end.join("\n")
    title = 'GTFS timetable validity'
    User.where(admin: true).find_each do |admin|
      next if Notification.exists?(user: admin, title:, content:)

      Notification.create!(user: admin, kind: :warning, title:, content:)
    end
    entries
  end
end
