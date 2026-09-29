#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/linting-checks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
sources=ios/BGMPrototype/Sources
checks=ios/Tests

run_check() {
  local name=$1
  shift
  printf '\nRunning %s\n' "$name"
  xcrun swiftc -O "$@" "$checks/$name.swift" -o "$check_dir/$name"
  "$check_dir/$name"
}

run_check PlaybackEvidenceChecks "$sources/PlaybackEvidence.swift"
run_check ScoreSemanticsChecks "$sources/PlaybackEvidence.swift" "$sources/AdaptivePreferenceModel.swift"
run_check TempoEstimatorChecks "$sources/TempoEstimator.swift" "$sources/PlaybackEvidence.swift" "$sources/AdaptivePreferenceModel.swift"
run_check SongAnalysisBudgetChecks "$sources/SongAnalysisBudget.swift"
run_check PhotoTimestampChecks "$sources/PhotoTimestamp.swift"
