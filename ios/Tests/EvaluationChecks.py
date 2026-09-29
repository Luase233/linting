"""Synthetic audit fixtures: time separation, missingness, label versions, no database mutation."""
import hashlib
import importlib.util
import json
import sqlite3
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("evaluation", root / "scripts/evaluate-recommendations.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)

with tempfile.TemporaryDirectory() as folder:
    path = Path(folder) / "fixture.sqlite"
    db = sqlite3.connect(path)
    for table in ["decisions", "playback_episodes", "feedback_events"]:
        db.execute(f"CREATE TABLE {table}(payload BLOB)")
    version = "observed-listening-fit-v2"
    for index in range(10):
        candidate = {"trackID": "fixture", "labelVersion": version,
                     "predictions": {"continuation": 0.5, "fit": 0.75}, "selectionRole": "main", "features": {"known": 1}}
        decision = {"id": str(index), "at": index, "chosenTrackID": "fixture", "policyVersion": "fixture-policy",
                    "selection": "bounded_top3_interest_exploration", "candidates": [candidate]}
        episode = {"decisionID": str(index), "trackID": "fixture", "labelVersion": version, "continuationTarget": index % 2}
        db.execute("INSERT INTO decisions VALUES(?)", (json.dumps(decision),))
        db.execute("INSERT INTO playback_episodes VALUES(?)", (json.dumps(episode),))
    # A censored observation, a legacy label, and a missing response must not become failures.
    for label, target in [(version, None), ("legacy", 0)]:
        db.execute("INSERT INTO playback_episodes VALUES(?)", (json.dumps({"decisionID": "9", "trackID": "fixture", "labelVersion": label, "continuationTarget": target}),))
    for time, kind in [(10, "suitable"), (11, "unsuitable")]:
        db.execute("INSERT INTO feedback_events VALUES(?)", (json.dumps({"at": time, "episodeID": "one-response", "decisionID": "9", "trackID": "fixture", "kind": kind, "labelVersion": version}),))
    for identifier, start, rendered in [("failed", "automatic", 0), ("test", "diagnostic", 12), ("audible", "automatic", 12)]:
        decision = {"id": identifier, "at": 20, "chosenTrackID": "fixture", "policyVersion": "fixture-policy",
                    "selection": "bounded_top3_interest_exploration", "candidates": [{"trackID": "fixture", "selectionRole": "explore", "features": {"known": 0}}]}
        episode = {"decisionID": identifier, "trackID": "fixture", "startReason": start, "renderedSeconds": rendered}
        db.execute("INSERT INTO decisions VALUES(?)", (json.dumps(decision),))
        db.execute("INSERT INTO playback_episodes VALUES(?)", (json.dumps(episode),))
    db.commit()
    db.close()
    before = hashlib.sha256(path.read_bytes()).digest()
    report = evaluation.evaluate(path)
    assert hashlib.sha256(path.read_bytes()).digest() == before
    continuation = report["targets"]["continuation"]
    assert continuation["qualified_total"] == 10
    assert continuation["later_20_percent"]["n"] == 2
    assert continuation["later_20_percent"]["brier"] == 0.25
    fit = report["targets"]["fit"]
    assert fit["qualified_total"] == 1 and fit["later_20_percent"]["positive"] == 1
    assert fit["later_20_percent"]["brier"] == 0.0625
    assert report["calibration_enabled"] is False
    assert report["exploration_selections"] == 2
    assert report["exploration_exposures"] == report["novel_exposures"] == 1
    assert report["confirmed_audible_exposures"] == 1
    assert report["context_sensitivity"]["health"]["experience_gain"] == "not_measured"
    assert evaluation.metrics([])["n"] == 0
    assert evaluation.wilson(0, 0) is None
    print("Evaluation checks passed: chronological slice, absent and legacy outcomes, first response, read-only database, no calibration claim.")
