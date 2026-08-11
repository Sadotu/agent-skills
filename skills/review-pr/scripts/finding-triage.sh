#!/usr/bin/env bash
# Pure classifier for one review-pr finding about state, timing, or races.
#
# Turns already-gathered evidence about ONE finding into a
# REPAIRABLE / DECISION-REQUIRED / SPLIT verdict, or refuses incomplete
# analysis. It reads nothing, runs
# nothing, and mutates nothing — it neither inspects the PR nor publishes
# anything. Fail-closed: missing, unusable, or incomplete replay evidence
# yields ANALYSIS-INCOMPLETE, which must not be published.
#
# Exit codes:
#   0  REPAIRABLE — publish it as a blocking (repairable) finding with a
#      mechanically actionable recommended action.
#   2  DECISION-REQUIRED — publish it as a blocking (decision required)
#      finding: state the invariant and the decision needed, and give NO
#      recommended action.
#   3  SPLIT — the finding bundles separable parts; split it and re-run this
#      classifier once per part.
#   4  ANALYSIS-INCOMPLETE — do not publish the finding; complete or correct
#      the required replay, then re-run this classifier.
#   1  usage error.
#
# Usage: finding-triage.sh --happy-path-replayed <yes|no>
#          --race-restart-transitions-replayed <yes|no> --preserves-issue-paths <yes|no>
#          --discriminator-matches-system-change <yes|no> --needs-additional-state <yes|no>
#          --separately-repairable-parts <yes|no>
set -euo pipefail

happy_path="" race_restart="" preserves_paths="" system_change="" additional_state="" separable=""

usage() {
  echo "usage: finding-triage.sh --happy-path-replayed <yes|no> \\" >&2
  echo "       --race-restart-transitions-replayed <yes|no> --preserves-issue-paths <yes|no> \\" >&2
  echo "       --discriminator-matches-system-change <yes|no> --needs-additional-state <yes|no> \\" >&2
  echo "       --separately-repairable-parts <yes|no>" >&2
  exit 1
}

# Each flag requires an explicit value: a trailing `--flag` with nothing after
# it is a usage error, not a silently empty (and therefore refusing) value.
require_value() {
  [ "$1" -ge 2 ] || { echo "--$2 requires a value (yes or no)" >&2; usage; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --happy-path-replayed)
      require_value "$#" happy-path-replayed; happy_path="$2"; shift 2;;
    --race-restart-transitions-replayed)
      require_value "$#" race-restart-transitions-replayed; race_restart="$2"; shift 2;;
    --preserves-issue-paths)
      require_value "$#" preserves-issue-paths; preserves_paths="$2"; shift 2;;
    --discriminator-matches-system-change)
      require_value "$#" discriminator-matches-system-change; system_change="$2"; shift 2;;
    --needs-additional-state)
      require_value "$#" needs-additional-state; additional_state="$2"; shift 2;;
    --separately-repairable-parts)
      require_value "$#" separately-repairable-parts; separable="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "unknown argument: $1" >&2; usage;;
  esac
done

decision() { echo "DECISION-REQUIRED: $1"; exit 2; }
incomplete() { echo "ANALYSIS-INCOMPLETE: $1; complete or correct the analysis before publication"; exit 4; }

# Fail-closed: every flag must be exactly yes or no. An unusable flag is a
# refusal, not a product decision — the reviewer did supply evidence, but must
# correct it before classification. Checked before SPLIT, so a compound finding
# with unusable evidence cannot skip the fail-closed gate.
for pair in "happy-path-replayed:$happy_path" \
            "race-restart-transitions-replayed:$race_restart" \
            "preserves-issue-paths:$preserves_paths" \
            "discriminator-matches-system-change:$system_change" \
            "needs-additional-state:$additional_state" \
            "separately-repairable-parts:$separable"; do
  name="${pair%%:*}" val="${pair#*:}"
  case "$val" in
    yes|no) ;;
    *) incomplete "evidence for --$name is missing or not yes/no";;
  esac
done

# Split next: a finding that bundles separable parts cannot carry a single
# verdict, so no other axis is meaningful until it has been split.
if [ "$separable" = yes ]; then
  echo "SPLIT: finding bundles independently repairable behavior with a part that is not; split it and re-run this classifier per part"
  exit 3
fi

[ "$happy_path"       = yes ] || incomplete "the expected success transition was not replayed through the proposed action"
[ "$race_restart"      = yes ] || incomplete "the named race/restart transitions were not replayed through the proposed action"
[ "$preserves_paths"  = yes ] || decision "the proposed action does not preserve every acceptance path the linked issue requires"
[ "$system_change"    = no  ] || decision "the proposed discriminator also matches a legitimate system-generated state change"
[ "$additional_state" = no  ] || decision "establishing the invariant needs state or provenance the application does not record"

echo "REPAIRABLE"
exit 0
