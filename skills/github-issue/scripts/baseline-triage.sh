#!/usr/bin/env bash
# Pure baseline-failure classifier for the unattended github-issue workflow.
#
# Turns already-captured evidence about ONE baseline test failure into a
# CONTINUE / STOP verdict. It runs nothing and mutates nothing — it does not
# execute, exclude, or alter any test. Fail-closed: missing or malformed
# evidence yields STOP.
#
# CONTINUE (exit 0) iff:
#   --reproduces-on-main yes  AND  --overlaps-surface no  AND
#   --branch-worsened     no  AND  --branch-resolved  no  AND  --ambiguous no
# Otherwise: prints "STOP: <reason>" and exits 2. Usage error exits 1.
set -euo pipefail

reproduces="" overlaps="" worsened="" resolved="" ambiguous=""

usage() {
  echo "usage: baseline-triage.sh --reproduces-on-main <yes|no> --overlaps-surface <yes|no> \\" >&2
  echo "       --branch-worsened <yes|no> --branch-resolved <yes|no> --ambiguous <yes|no>" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reproduces-on-main) reproduces="${2-}"; shift 2;;
    --overlaps-surface)   overlaps="${2-}";   shift 2;;
    --branch-worsened)    worsened="${2-}";   shift 2;;
    --branch-resolved)    resolved="${2-}";   shift 2;;
    --ambiguous)          ambiguous="${2-}";  shift 2;;
    -h|--help)            usage;;
    *) echo "unknown argument: $1" >&2; usage;;
  esac
done

stop() { echo "STOP: $1"; exit 2; }

# Fail-closed: every flag must be exactly yes or no.
for pair in "reproduces-on-main:$reproduces" "overlaps-surface:$overlaps" \
            "branch-worsened:$worsened" "branch-resolved:$resolved" \
            "ambiguous:$ambiguous"; do
  name="${pair%%:*}" val="${pair#*:}"
  case "$val" in
    yes|no) ;;
    *) stop "evidence for --$name is missing or not yes/no; cannot classify confidently";;
  esac
done

[ "$reproduces" = yes ] || stop "failure does not reproduce on untouched origin/main"
[ "$overlaps"   = no  ] || stop "failure overlaps the issue's change surface"
[ "$worsened"   = no  ] || stop "failure is new or materially worse/different on the issue branch"
[ "$resolved"   = no  ] || stop "issue branch resolves the failure without a reviewed in-scope explanation"
[ "$ambiguous"  = no  ] || stop "failure is flaky/environmental/unclassifiable"

echo "CONTINUE"
exit 0
