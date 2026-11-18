# frozen_string_literal: true

# Whose walks the map's walk layer shows, each owner in its own colour
# (Bator, 2026-11-18: "különböző színnel jelezzük, hogy kié melyik séta").
#
# A TrackPick source account (TrackPick::Config.source_users: one person's
# phone and GPS logger accounts) sees the walks of every source account; the
# viewer's own walks keep the walk colour, the others get OTHER_COLORS in
# source order. Anyone else sees only their own walks, as before.
#
# Privacy: another owner's walks pass that owner's visibility rules and the
# viewer's privacy zones too (#zones), so nothing the viewer hides shows up
# through a second account.
class Gtfs::WalkOwners
  OWN_COLOR = '#334155' # WALK_COLOR in walk_legs_layer.js
  # Not a Budapest line colour family (metro red/blue/green/yellow, tram
  # yellow, bus blue, trolley red); a walk is dashed besides.
  OTHER_COLORS = ['#7C3AED', '#C2410C'].freeze

  Owner = Struct.new(:user, :color, :label, :own, keyword_init: true)

  def self.for(viewer)
    group = TrackPick::Config.source_users
    own = Owner.new(user: viewer, color: OWN_COLOR, label: nil, own: true)
    return [own] unless group.size > 1 && group.any? { |u| u.id == viewer.id }

    own.label = label(viewer)
    others = group.reject { |u| u.id == viewer.id }.each_with_index.map do |user, index|
      Owner.new(user:, color: OTHER_COLORS[index % OTHER_COLORS.size], label: label(user), own: false)
    end
    [own] + others
  end

  # Full name, else the e-mail's handle (never the whole address).
  def self.label(user)
    Gtfs::Discord::Config.user_label(user)
  end

  # The owner's privacy zones and, for another owner's walks, the viewer's.
  def self.zones(owner, viewer)
    zones = Users::PrivacyZones.new(owner.user).call
    owner.own ? zones : zones + Users::PrivacyZones.new(viewer).call
  end
end
