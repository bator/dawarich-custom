#!/bin/bash
# Runs test/*_test.rb inside the Dawarich app on CT 139 (rails runner, no database writes).
# The repo's files/ tree is copied over and loaded on top of the deployed code first, so the
# working tree is what gets tested. Usage: test/run.sh [test/some_test.rb ...]
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${DC_TEST_HOST:-root@192.168.1.139}
tests=("$@"); [ ${#tests[@]} -eq 0 ] && tests=(test/*_test.rb)
tar czf - files test | ssh "$HOST" 'rm -rf /tmp/dc-test && mkdir -p /tmp/dc-test && tar xzf - -C /tmp/dc-test'
list=$(printf "/tmp/dc-test/%s " "${tests[@]}")
ssh "$HOST" "export LC_ALL=C; cd /opt/dawarich/app && printf 'ARGV.clear\n%s\n' \"$(for t in $list; do printf "require '%s'; " "$t"; done)\" > /tmp/dc-test/all.rb && systemd-run --wait --pipe -q -p WorkingDirectory=/opt/dawarich/app -p EnvironmentFile=/opt/dawarich/.env -p EnvironmentFile=-/opt/dawarich/gtfs.env /root/.rbenv/shims/bundle exec bin/rails runner /tmp/dc-test/all.rb 2>&1 | grep -vE 'OIDC:|Prometheus|perl:'; status=\${PIPESTATUS[0]}; rm -rf /tmp/dc-test; exit \$status"
