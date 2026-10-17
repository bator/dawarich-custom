# frozen_string_literal: true

# Texts of the public transit (GTFS) feature: English and Hungarian (spec
# 12.6). They live in their own folder because the other locales of the app
# do not translate them yet; those fall back to English (i18n fallbacks).
# Hungarian is used once a `hu` locale is enabled in config.i18n.available_locales.
Rails.application.config.i18n.load_path += Dir[Rails.root.join('config/locales/transit/*.yml')]
