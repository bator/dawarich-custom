#!/usr/bin/env bash
# dawarich-custom on Proxmox VE in one command, run as root on the node:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/bator/dawarich-custom/main/install/proxmox.sh)"
#
# Finds the community-scripts Dawarich container(s) on this node, or offers to
# create one with the community-scripts installer first, then runs
# install/lxc.sh inside it. Environment:
#   CTID=123    use this container, no questions
#   NEW=1       create a new Dawarich container first (community-scripts ct/dawarich.sh;
#               its var_* settings and mode=default work as usual)
#   BRANCH=main REPO_URL=...   what to install
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/bator/dawarich-custom.git}
BRANCH=${BRANCH:-main}
RAW_URL=${RAW_URL:-https://raw.githubusercontent.com/bator/dawarich-custom/$BRANCH}
CS_URL=${CS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/dawarich.sh}

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ask() { # question default(y/n) -> 0 yes
  local answer
  [ -t 0 ] || { [ "$2" = y ]; return; }
  read -r -p "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )] " answer
  answer=${answer:-$2}
  [[ $answer =~ ^[Yy] ]]
}

command -v pct >/dev/null || die "run this on a Proxmox VE node (pct not found)"
[ "$(id -u)" = 0 ] || die "run as root"

# Running containers on this node with a community-scripts Dawarich in them.
dawarich_cts() {
  pct list | awk 'NR > 1 && $2 == "running" { print $1 }' | while read -r id; do
    if pct exec "$id" -- test -d /opt/dawarich/app -a -f /opt/dawarich/.env 2>/dev/null; then
      echo "$id"
    fi
  done
}

if [ -z "${CTID:-}" ]; then
  if [ "${NEW:-0}" != 1 ]; then
    mapfile -t found < <(dawarich_cts)
  else
    found=()
  fi
  if [ ${#found[@]} -eq 0 ]; then
    if [ "${NEW:-0}" = 1 ] || ask "No Dawarich container on this node. Create one with the community-scripts installer now?" y; then
      before=$(pct list | awk 'NR > 1 { print $1 }' | sort)
      say "community-scripts Dawarich installer ($CS_URL)"
      bash -c "$(curl -fsSL "$CS_URL")"
      after=$(pct list | awk 'NR > 1 { print $1 }' | sort)
      CTID=$(comm -13 <(echo "$before") <(echo "$after") | tail -1)
      [ -n "$CTID" ] || die "could not find the new container; run again with CTID=<id>"
    else
      die "nothing to do; create a Dawarich container first or pass CTID=<id>"
    fi
  elif [ ${#found[@]} -eq 1 ]; then
    CTID=${found[0]}
    ask "Install dawarich-custom into CT $CTID ($(pct config "$CTID" | awk '/^hostname:/ { print $2 }'))?" y || die "cancelled"
  else
    echo "Dawarich containers on this node: ${found[*]}"
    [ -t 0 ] || die "several found; pass CTID=<id>"
    read -r -p "Which one? " CTID
  fi
fi

pct status "$CTID" >/dev/null 2>&1 || die "CT $CTID is not on this node"
pct status "$CTID" | grep -q running || die "CT $CTID is not running"
pct exec "$CTID" -- test -d /opt/dawarich/app || die "CT $CTID has no /opt/dawarich/app (not a community-scripts Dawarich)"

say "installing dawarich-custom ($BRANCH) into CT $CTID"
script=$(mktemp)
trap 'rm -f "$script"' EXIT
curl -fsSL "$RAW_URL/install/lxc.sh" -o "$script"
pct push "$CTID" "$script" /root/dawarich-custom-lxc.sh --perms 0700
pct exec "$CTID" -- env REPO_URL="$REPO_URL" BRANCH="$BRANCH" bash /root/dawarich-custom-lxc.sh
pct exec "$CTID" -- rm -f /root/dawarich-custom-lxc.sh
