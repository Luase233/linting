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
run_check AdaptivePreferenceModelChecks "$sources/PlaybackEvidence.swift" "$sources/AdaptivePreferenceModel.swift" "$sources/AdaptiveDecisionStore.swift" "$sources/ListeningDatabase.swift"
run_check TempoEstimatorChecks "$sources/TempoEstimator.swift" "$sources/PlaybackEvidence.swift" "$sources/AdaptivePreferenceModel.swift"
run_check SongAnalysisBudgetChecks "$sources/SongAnalysisBudget.swift"
run_check PhotoTimestampChecks "$sources/PhotoTimestamp.swift"
run_check ListeningIntentContextChecks "$sources/Models.swift" "$sources/HealthFeatures.swift" "$sources/ListeningIntentContext.swift"
sed '/^@MainActor/,$d' "$sources/LocationContextManager.swift" > "$check_dir/PlaceModels.swift"
run_check PlaceContextChecks "$check_dir/PlaceModels.swift" "$sources/MapCoordinateAdapter.swift"
run_check RecommendationPreparationChecks "$sources/Models.swift" "$sources/HealthFeatures.swift" "$sources/ListeningIntentContext.swift" "$sources/PlaybackEvidence.swift" "$sources/AdaptivePreferenceModel.swift" "$sources/AdaptiveDecisionStore.swift" "$sources/ListeningDatabase.swift" "$sources/LocalRecommendationEngine.swift"
python3 "$checks/EvaluationChecks.py"
