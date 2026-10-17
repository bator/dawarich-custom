# frozen_string_literal: true

# Matcher state of one user (review A5): backfill progress and the result of
# the last scheduled match run. Kept out of users.settings so that the
# settings page and the jobs never overwrite each other.
class Gtfs::UserState < ApplicationRecord
  belongs_to :user

  def self.for(user)
    find_or_create_by!(user_id: user.id)
  rescue ActiveRecord::RecordNotUnique
    find_by!(user_id: user.id)
  end

  # Read-modify-write of one jsonb column under a row lock.
  def self.update_json!(user, column)
    state = self.for(user)
    state.with_lock do
      value = yield(state.public_send(column).dup)
      state.update!(column => value)
      value
    end
  end
end
