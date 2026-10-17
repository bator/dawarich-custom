# frozen_string_literal: true

# GET /api/v1/transit/feeds: state of the timetables (last import, validity,
# attribution). Disabled feeds and import errors only for admins.
class Api::V1::Transit::FeedsController < Api::V1::Transit::BaseController
  def index
    feeds = current_api_user.admin? ? Gtfs::Feed.all : Gtfs::Feed.enabled
    render json: { data: feeds.order(:key).map { |feed| feed_json(feed) } }
  end

  private

  def feed_json(feed)
    data = {
      key: feed.key, name: feed.name, enabled: feed.enabled, imported: feed.imported?,
      status: feed.status, last_imported_at: feed.last_imported_at&.iso8601,
      valid_from: feed.valid_from&.iso8601, valid_until: feed.valid_until&.iso8601,
      expired: feed.expired?, expiring_soon: feed.expiring_soon?,
      attribution: feed.attribution.presence, license_url: feed.license_url.presence
    }
    return data unless current_api_user.admin?

    data.merge(last_error: feed.last_error, last_checked_at: feed.last_checked_at&.iso8601)
  end
end
