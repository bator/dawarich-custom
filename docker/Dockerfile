# syntax=docker/dockerfile:1
# Dawarich (https://github.com/Freika/dawarich) with this repo's custom code
# (GTFS/transit, Discord bot, track_pick) on top of its official image,
# freikin/dawarich on Docker Hub: the image upstream's docker/docker-compose.yml
# uses, built from upstream's docker/Dockerfile. Build from the repo root:
#
#   docker build -f docker/Dockerfile -t dawarich-custom:1.18.0 .
#
# docs/docker.md describes the whole setup (compose, env, first start).
ARG DAWARICH_VERSION=1.18.0

FROM freikin/dawarich:${DAWARICH_VERSION} AS upstream

# 1. The merge restore_custom.py does after an LXC upgrade: ours/ is 3-way
#    merged into the upstream files, files/ is added. A conflict, or a custom
#    path that upstream now uses itself, stops the build (nothing half-done).
FROM python:3.12-slim AS overlay
ARG DAWARICH_VERSION
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
# every top-level path the manifest touches, so the "path already exists" guard sees them
COPY --from=upstream /var/app/app /upstream/app
COPY --from=upstream /var/app/config /upstream/config
COPY --from=upstream /var/app/db /upstream/db
COPY --from=upstream /var/app/lib /upstream/lib
COPY --from=upstream /var/app/spec /upstream/spec
COPY --from=upstream /var/app/Gemfile /var/app/Gemfile.lock /upstream/
COPY restore_custom.py manifest.json /repo/
COPY files /repo/files
COPY ours /repo/ours
COPY upstream /repo/upstream
RUN DAWARICH_APP=/upstream DAWARICH_CUSTOM_STATE=/tmp/dawarich-custom \
    python3 /repo/restore_custom.py export /overlay --version "${DAWARICH_VERSION}"

# 2. The upstream image with the merged files, then the same gem and asset
#    steps as the upstream Dockerfile (Tailwind has to see the custom views).
FROM upstream
ARG DAWARICH_VERSION
LABEL org.opencontainers.image.title="dawarich-custom" \
      org.opencontainers.image.description="Dawarich ${DAWARICH_VERSION} (github.com/Freika/dawarich) with GTFS public transport matching" \
      org.opencontainers.image.source="https://github.com/bator/dawarich-custom" \
      org.opencontainers.image.base.name="docker.io/freikin/dawarich:${DAWARICH_VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0"

COPY --from=overlay /overlay/ /var/app/

# chunky_png (Discord map images) is already in the lock through rqrcode;
# this only records it, or installs what a newer ours/Gemfile adds.
RUN bundle install --jobs 4 --retry 3 \
    && rm -rf vendor/bundle/ruby/*/cache/*.gem

RUN rm -rf public/assets \
    && npm ci --no-audit --no-fund \
    && SECRET_KEY_BASE_DUMMY=1 bundle exec rake assets:precompile \
    && rm -rf node_modules tmp/cache ~/.npm \
    && mkdir -p tmp/pids tmp/cache tmp/sockets \
    && chmod -R 777 tmp \
    && rm -rf public_dist \
    && cp -r public public_dist

COPY docker/bot-entrypoint.sh /usr/local/bin/bot-entrypoint.sh
RUN chmod +x /usr/local/bin/bot-entrypoint.sh
