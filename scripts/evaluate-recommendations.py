#!/usr/bin/env python3
"""Read-only, aggregate audit of versioned on-device predictions. Never uploads data."""
import argparse
import json
import math
import sqlite3
from pathlib import Path


def wilson(positive, total):
    if not total:
        return None
    z = 1.96
    rate = positive / total
    scale = 1 + z * z / total
    center = (rate + z * z / (2 * total)) / scale
    radius = z * math.sqrt(rate * (1 - rate) / total + z * z / (4 * total * total)) / scale
    return [max(0, center - radius), min(1, center + radius)]


def metrics(rows):
    if not rows:
        return {"n": 0, "status": "no_qualified_outcomes"}
    predictions = [min(1 - 1e-12, max(1e-12, r[1])) for r in rows]
    outcomes = [r[2] for r in rows]
    bins = []
    for lower in range(0, 10):
        selected = [(p, y) for p, y in zip(predictions, outcomes) if min(9, int(p * 10)) == lower]
        bins.append({"range": [lower / 10, (lower + 1) / 10], "n": len(selected),
                     "mean_prediction": sum(p for p, _ in selected) / len(selected) if selected else None,
                     "observed_rate": sum(y for _, y in selected) / len(selected) if selected else None,
                     "rate_wilson_95": wilson(sum(y for _, y in selected), len(selected))})
    return {"n": len(rows), "positive": sum(outcomes),
            "brier": sum((p - y) ** 2 for p, y in zip(predictions, outcomes)) / len(rows),
            "log_loss": -sum(y * math.log(p) + (1 - y) * math.log(1 - p) for p, y in zip(predictions, outcomes)) / len(rows),
            "reliability_bins": bins,
            "status": "descriptive_only_not_calibration_approval"}


def evaluate(path):
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    decisions = {row["id"]: row for (data,) in db.execute("SELECT payload FROM decisions") for row in [json.loads(data)]}
    episodes = [json.loads(data) for (data,) in db.execute("SELECT payload FROM playback_episodes")]
    events = [json.loads(data) for (data,) in db.execute("SELECT payload FROM feedback_events")]
    samples = {"continuation": [], "fit": []}

    def add(target, observation, outcome):
        decision = decisions.get(observation.get("decisionID"))
        if not decision or observation.get("labelVersion") != "observed-listening-fit-v2":
            return
        candidate = next((c for c in decision["candidates"] if c["trackID"] == observation["trackID"]), None)
        if not candidate or candidate.get("labelVersion") != observation["labelVersion"]:
            return
        p = candidate.get("predictions", {}).get(target)
        if isinstance(p, (int, float)) and math.isfinite(p) and 0 <= p <= 1 and outcome in (0, 1):
            samples[target].append((decision["at"], p, outcome, decision["policyVersion"]))

    for episode in episodes:
        if episode.get("continuationTarget") is not None:
            add("continuation", episode, episode["continuationTarget"])
    # First explicit response per episode avoids counting repeated corrections as independent labels.
    responded = set()
    for event in sorted(events, key=lambda row: row["at"]):
        if event.get("kind") not in ("suitable", "unsuitable") or event.get("labelVersion") != "observed-listening-fit-v2":
            continue
        if event["episodeID"] in responded:
            continue
        responded.add(event["episodeID"])
        add("fit", event, int(event["kind"] == "suitable"))

    result = {"scope": "stored_predecision_predictions_on_later_time_slice",
              "calibration_enabled": False,
              "limitations": ["Online models continue learning; this is a chronological prequential audit, not a frozen-model randomized trial.",
                              "Repeated listens are correlated. Binomial intervals are descriptive and may understate uncertainty.",
                              "Missing/censored outcomes are excluded, not negative labels. Voluntary fit responses may be selection-biased.",
                              "No claim of causal gain, calibrated suitability, or cross-policy improvement."], "targets": {}}
    for target, observations in samples.items():
        ordered = sorted(observations, key=lambda row: row[0])
        # Keep all observations with the same timestamp in the same chronological slice.
        cutoff = ordered[int(len(ordered) * 0.8)][0] if ordered else None
        later = [row for row in ordered if row[0] >= cutoff] if cutoff is not None else []
        result["targets"][target] = {"qualified_total": len(ordered), "later_20_percent": metrics(later),
                                      "by_policy_later": {policy: metrics([r for r in later if r[3] == policy]) for policy in sorted({r[3] for r in later})}}

    diagnostic = {e.get("decisionID") for e in episodes if e.get("startReason") in ("diagnostic", "system", "device_smoke")}
    diagnostic.update(e.get("decisionID") for e in events if (e.get("action") or {}).get("source") == "diagnostic")
    automatic = [d for d in decisions.values() if d.get("selection") == "bounded_top3_interest_exploration" and d["id"] not in diagnostic]
    rendered = {e.get("decisionID") for e in episodes if e.get("decisionID") not in diagnostic
                and isinstance(e.get("renderedSeconds"), (int, float)) and e["renderedSeconds"] > 0}
    exposed = [d for d in automatic if d["id"] in rendered]
    influences = {}
    for source in ("visual", "place", "health"):
        rows = [i for d in automatic for i in d.get("contextInfluences", []) if i["source"] == source]
        influences[source] = {"decisions": len(rows), "with_signal": sum(r["coverage"] > 0 for r in rows),
                              "rank_changed": sum(r["rankingChanged"] for r in rows),
                              "mean_total_variation": sum(r["totalVariation"] for r in rows) / len(rows) if rows else None,
                              "experience_gain": "not_measured"}
    result["context_sensitivity"] = influences
    result["retained_automatic_decisions"] = len(automatic)
    result["confirmed_audible_exposures"] = len(exposed)
    result["exposure_scope"] = "Completed stored episodes with actual audio output; failed/cancelled selections and diagnostic runs excluded. Active unflushed episodes are not counted."
    result["exploration_selections"] = sum(next((c.get("selectionRole") == "explore" for c in d["candidates"] if c["trackID"] == d["chosenTrackID"]), False) for d in automatic)
    result["exploration_exposures"] = sum(next((c.get("selectionRole") == "explore" for c in d["candidates"] if c["trackID"] == d["chosenTrackID"]), False) for d in exposed)
    result["novel_exposures"] = sum(next((c.get("features", {}).get("known") == 0 for c in d["candidates"] if c["trackID"] == d["chosenTrackID"]), False) for d in exposed)
    db.close()
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path, help="Local copy of linting-v2.sqlite; keep its WAL alongside it if present")
    args = parser.parse_args()
    print(json.dumps(evaluate(args.database), ensure_ascii=False, indent=2))
