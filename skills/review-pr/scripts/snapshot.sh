#!/usr/bin/env bash
# Prints the current review snapshot for a PR/issue pair as JSON.
#
# Usage: snapshot.sh <pr-number> <issue-number>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: snapshot.sh <pr-number> <issue-number>" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"
source "$script_dir/lib/marker.sh"
source "$script_dir/lib/snapshot.sh"

compute_snapshot_json "$1" "$2"
