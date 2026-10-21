"""
validate.py — Compare SQL WAR output to JS pipeline ground truth

Loads war_lookup_reference.json (from softballPlayerWAR.js output),
queries the SQLite database for combined WAR values, and reports:
  - Correlation between SQL and JS WAR
  - Mean absolute difference
  - Max discrepancy
  - Per-player comparison for top players

Usage:
    python scripts/validate.py
"""

import json
import math
import os
import sqlite3
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_DIR = os.path.join(PROJECT_DIR, "sql")
DATA_DIR = os.path.join(PROJECT_DIR, "data")
DB_PATH = os.path.join(PROJECT_DIR, "ncaa_softball.db")
REFERENCE_PATH = os.path.join(DATA_DIR, "war_lookup_reference.json")

# Team ID normalization: JS reference uses raw Firestore team IDs,
# SQL pipeline normalizes them. Map raw → canonical for matching.
TEAM_ALIASES = {
    "florida-state": "florida-st",
    "mississippi-state": "mississippi-st",
    "oklahoma-state": "oklahoma-st",
    "ohio-state": "ohio-st",
    "oklahoma-sooners": "oklahoma",
    "pitt": "pittsburgh",
    "penn-state": "penn-st",
    "michigan-st": "michigan-state",
    "nc-state": "north-carolina-state",
    "iowa-state": "iowa-st",
    "cal": "california",
    "arizona-st": "arizona-state",
    "st-johns": "st-johns-ny",
}


def normalize_team(team_short):
    return TEAM_ALIASES.get(team_short, team_short)


def register_functions(conn):
    conn.create_function("POWER", 2, lambda base, exp: math.pow(base, exp))


def compute_r_squared(x, y):
    n = len(x)
    if n < 3:
        return 0.0
    xm = sum(x) / n
    ym = sum(y) / n
    ss_xy = sum((xi - xm) * (yi - ym) for xi, yi in zip(x, y))
    ss_xx = sum((xi - xm) ** 2 for xi in x)
    ss_yy = sum((yi - ym) ** 2 for yi in y)
    if ss_xx == 0 or ss_yy == 0:
        return 0.0
    r = ss_xy / math.sqrt(ss_xx * ss_yy)
    return r ** 2


def main():
    if not os.path.exists(DB_PATH):
        print(f"ERROR: Database not found at {DB_PATH}")
        sys.exit(1)

    if not os.path.exists(REFERENCE_PATH):
        print(f"ERROR: Reference file not found at {REFERENCE_PATH}")
        print("Run the Firestore export first to copy war_lookup_reference.json")
        sys.exit(1)

    # Load ground truth and normalize team IDs in keys
    with open(REFERENCE_PATH, "r") as f:
        raw_reference = json.load(f)

    reference = {}
    for key, vals in raw_reference.items():
        parts = key.split("::")
        if len(parts) == 2:
            name, team = parts
            norm_team = normalize_team(team)
            new_key = f"{name}::{norm_team}"
            # If normalized key already exists, merge (sum WAR values)
            if new_key in reference:
                existing = reference[new_key]
                existing["totalWAR"] += vals["totalWAR"]
                existing["battingWAR"] += vals["battingWAR"]
                existing["pitchingWAR"] += vals.get("pitchingWAR", 0)
                existing["pa"] += vals["pa"]
                existing["ip"] += vals["ip"]
            else:
                reference[new_key] = dict(vals)
        else:
            reference[key] = vals

    print(f"\nLoaded {len(reference)} players from JS pipeline reference")

    # Query SQL database for combined WAR
    conn = sqlite3.connect(DB_PATH)
    register_functions(conn)

    sql_path = os.path.join(SQL_DIR, "06_combined_war.sql")
    with open(sql_path, "r") as f:
        sql = f.read()

    cursor = conn.execute(sql)
    cols = [desc[0] for desc in cursor.description]
    rows = cursor.fetchall()

    ci = {name: idx for idx, name in enumerate(cols)}

    # Build SQL lookup: "name::team" -> WAR values
    sql_lookup = {}
    for row in rows:
        player_name = (row[ci["player_name"]] or "").strip()
        team_id = (row[ci["team_id"]] or "").strip()
        team_short = team_id.replace("ncaasb_", "")
        clean_name = player_name.lower()
        key = f"{clean_name}::{team_short}"

        sql_lookup[key] = {
            "total_war": row[ci["total_war"]] or 0,
            "batting_war": row[ci["batting_war"]] or 0,
            "pitching_war": row[ci["pitching_war"]] or 0,
            "pa": row[ci["pa"]] or 0,
            "ip": row[ci["ip"]] or 0,
        }

    print(f"SQL pipeline produced {len(sql_lookup)} players\n")

    # Match players between JS and SQL
    matched = []
    unmatched_js = []

    for js_key, js_vals in reference.items():
        if js_key in sql_lookup:
            sql_vals = sql_lookup[js_key]
            matched.append({
                "key": js_key,
                "js_total": js_vals["totalWAR"],
                "sql_total": sql_vals["total_war"],
                "js_bat": js_vals["battingWAR"],
                "sql_bat": sql_vals["batting_war"],
                "js_pitch": js_vals.get("pitchingWAR", 0),
                "sql_pitch": sql_vals["pitching_war"],
                "diff": abs(js_vals["totalWAR"] - sql_vals["total_war"]),
            })
        else:
            unmatched_js.append(js_key)

    print(f"Matched: {len(matched)} players")
    print(f"Unmatched (JS only): {len(unmatched_js)}")
    print(f"SQL only: {len(sql_lookup) - len(matched)}\n")

    if not matched:
        print("ERROR: No players matched between JS and SQL pipelines")
        conn.close()
        sys.exit(1)

    # ---- Correlation ----
    js_wars = [m["js_total"] for m in matched]
    sql_wars = [m["sql_total"] for m in matched]
    r2_total = compute_r_squared(js_wars, sql_wars)

    js_bats = [m["js_bat"] for m in matched]
    sql_bats = [m["sql_bat"] for m in matched]
    r2_bat = compute_r_squared(js_bats, sql_bats)

    js_pitch = [m["js_pitch"] for m in matched]
    sql_pitch = [m["sql_pitch"] for m in matched]
    r2_pitch = compute_r_squared(js_pitch, sql_pitch)

    # ---- Error stats ----
    diffs = [m["diff"] for m in matched]
    mean_diff = sum(diffs) / len(diffs)
    max_diff = max(diffs)
    within_005 = sum(1 for d in diffs if d <= 0.05)
    within_010 = sum(1 for d in diffs if d <= 0.10)
    within_050 = sum(1 for d in diffs if d <= 0.50)

    print("=" * 60)
    print("  VALIDATION RESULTS")
    print("=" * 60)
    print(f"\n  R2 (Total WAR):    {r2_total:.4f}")
    print(f"  R2 (Batting WAR):  {r2_bat:.4f}")
    print(f"  R2 (Pitching WAR): {r2_pitch:.4f}")
    print(f"\n  Mean abs diff:     {mean_diff:.4f}")
    print(f"  Max abs diff:      {max_diff:.4f}")
    print(f"  Within +/-0.05:    {within_005}/{len(matched)} ({100*within_005/len(matched):.1f}%)")
    print(f"  Within +/-0.10:    {within_010}/{len(matched)} ({100*within_010/len(matched):.1f}%)")
    print(f"  Within +/-0.50:    {within_050}/{len(matched)} ({100*within_050/len(matched):.1f}%)")

    # ---- Top player comparison ----
    print(f"\n  {'-' * 75}")
    print(f"  {'Player':<30s} {'JS WAR':>8s} {'SQL WAR':>8s} {'Diff':>8s}")
    print(f"  {'-' * 70}")

    matched.sort(key=lambda m: m["js_total"], reverse=True)
    for m in matched[:20]:
        display = m["key"][:29]
        sign = "+" if m["sql_total"] - m["js_total"] >= 0 else ""
        print(f"  {display:<30s} {m['js_total']:>+8.2f} {m['sql_total']:>+8.2f} "
              f"{sign}{m['sql_total'] - m['js_total']:>7.2f}")

    # ---- Largest discrepancies ----
    matched.sort(key=lambda m: m["diff"], reverse=True)
    print(f"\n  LARGEST DISCREPANCIES:")
    print(f"  {'-' * 70}")
    for m in matched[:10]:
        display = m["key"][:29]
        sign = "+" if m["sql_total"] - m["js_total"] >= 0 else ""
        print(f"  {display:<30s} {m['js_total']:>+8.2f} {m['sql_total']:>+8.2f} "
              f"{sign}{m['sql_total'] - m['js_total']:>7.2f}")

    conn.close()
    print("\nValidation complete.\n")


if __name__ == "__main__":
    main()
