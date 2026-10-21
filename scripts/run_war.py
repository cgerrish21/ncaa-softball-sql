"""
run_war.py — Execute WAR queries and print formatted leaderboards

Runs all SQL files against ncaa_softball.db, prints results,
and exports CSVs to output/.

Usage:
    python scripts/run_war.py
"""

import csv
import math
import os
import sqlite3
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_DIR = os.path.join(PROJECT_DIR, "sql")
OUTPUT_DIR = os.path.join(PROJECT_DIR, "output")
DB_PATH = os.path.join(PROJECT_DIR, "ncaa_softball.db")


def register_functions(conn):
    conn.create_function("POWER", 2, lambda base, exp: math.pow(base, exp))


def read_sql(filename):
    filepath = os.path.join(SQL_DIR, filename)
    with open(filepath, "r") as f:
        return f.read()


def execute_query(conn, sql):
    """Execute a query and return (rows, column_names)."""
    cursor = conn.execute(sql)
    columns = [desc[0] for desc in cursor.description] if cursor.description else []
    rows = cursor.fetchall()
    return rows, columns


def export_csv(rows, columns, filename):
    filepath = os.path.join(OUTPUT_DIR, filename)
    with open(filepath, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(columns)
        writer.writerows(rows)
    return filepath


def compute_r_squared(x_vals, y_vals):
    """Compute R² between two lists of numbers."""
    n = len(x_vals)
    if n < 3:
        return 0.0
    x_mean = sum(x_vals) / n
    y_mean = sum(y_vals) / n
    ss_xy = sum((x - x_mean) * (y - y_mean) for x, y in zip(x_vals, y_vals))
    ss_xx = sum((x - x_mean) ** 2 for x in x_vals)
    ss_yy = sum((y - y_mean) ** 2 for y in y_vals)
    if ss_xx == 0 or ss_yy == 0:
        return 0.0
    r = ss_xy / math.sqrt(ss_xx * ss_yy)
    return r ** 2


def main():
    if not os.path.exists(DB_PATH):
        print(f"ERROR: Database not found at {DB_PATH}")
        print("Run create_db.py first: python scripts/create_db.py")
        sys.exit(1)

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    register_functions(conn)

    # ==========================================================
    # League Averages
    # ==========================================================
    print("\n" + "=" * 60)
    print("  LEAGUE AVERAGES")
    print("=" * 60)

    sql = read_sql("03_league_averages.sql")
    # Execute each statement separately (file has 3 SELECT statements)
    # Strip SQL comments before checking if it's a SELECT
    def is_select(stmt):
        lines = [l for l in stmt.split("\n") if not l.strip().startswith("--")]
        return "\n".join(lines).strip().upper().startswith("SELECT")
    statements = [s.strip() for s in sql.split(";") if s.strip() and is_select(s)]

    for stmt in statements:
        rows, cols = execute_query(conn, stmt)
        if rows:
            for i, col in enumerate(cols):
                val = rows[0][i]
                if isinstance(val, float):
                    print(f"  {col:20s}: {val:.4f}")
                elif val is not None:
                    print(f"  {col:20s}: {val}")

    # ==========================================================
    # Batting WAR Leaderboard
    # ==========================================================
    print("\n" + "=" * 60)
    print("  TOP 30 BATTERS BY WAR")
    print("=" * 60 + "\n")

    bat_sql = read_sql("04_batting_war.sql")
    bat_rows, bat_cols = execute_query(conn, bat_sql)

    # Header
    print(f"  {'#':>3s}  {'Name':<24s} {'Team':<16s} {'Pos':<4s} "
          f"{'PA':>4s} {'AVG':>6s} {'OBP':>6s} {'SLG':>6s} {'wOBA':>6s} "
          f"{'wRAA':>7s} {'WAR':>6s}")
    print(f"  {'-' * 105}")

    # Find column indexes
    ci = {name: idx for idx, name in enumerate(bat_cols)}
    for i, row in enumerate(bat_rows[:30]):
        name = (row[ci["player_name"]] or "")[:23]
        team_name = (row[ci.get("team_name", ci.get("team_id"))] or "")[:15]
        pos = (row[ci["position"]] or "")[:4]
        pa = row[ci["pa"]] or 0
        avg = row[ci["avg"]] or 0
        obp = row[ci["obp"]] or 0
        slg = row[ci["slg"]] or 0
        woba = row[ci["woba"]] or 0
        wraa = row[ci["wraa"]] or 0
        war = row[ci["batting_war"]] or 0
        sign = "+" if wraa >= 0 else ""
        wsign = "+" if war >= 0 else ""
        print(f"  {i+1:>3d}  {name:<24s} {team_name:<16s} {pos:<4s} "
              f"{pa:>4d} {avg:>6.3f} {obp:>6.3f} {slg:>6.3f} {woba:>6.3f} "
              f"{sign}{wraa:>6.1f} {wsign}{war:>5.2f}")

    # Export full batting WAR
    bat_path = export_csv(bat_rows, bat_cols, "batting_war.csv")
    print(f"\n  Exported: {bat_path} ({len(bat_rows)} players)")

    # ==========================================================
    # Pitching WAR Leaderboard
    # ==========================================================
    print("\n" + "=" * 60)
    print("  TOP 20 PITCHERS BY WAR")
    print("=" * 60 + "\n")

    pitch_sql = read_sql("05_pitching_war.sql")
    pitch_rows, pitch_cols = execute_query(conn, pitch_sql)

    pi = {name: idx for idx, name in enumerate(pitch_cols)}
    print(f"  {'#':>3s}  {'Name':<24s} {'Team':<16s} "
          f"{'IP':>6s} {'ERA':>6s} {'xERA':>6s} {'K/7':>5s} {'WHIP':>6s} {'pWAR':>6s}")
    print(f"  {'-' * 90}")

    for i, row in enumerate(pitch_rows[:20]):
        name = (row[pi["player_name"]] or "")[:23]
        team_name = (row[pi.get("team_name", pi.get("team_id"))] or "")[:15]
        ip = row[pi["ip"]] or 0
        era = row[pi["era"]] or 0
        xera = row[pi["xera"]] or 0
        k7 = row[pi["k7"]] or 0
        whip = row[pi["whip"]] or 0
        pwar = row[pi["pitching_war"]] or 0
        wsign = "+" if pwar >= 0 else ""
        print(f"  {i+1:>3d}  {name:<24s} {team_name:<16s} "
              f"{ip:>6.1f} {era:>6.2f} {xera:>6.2f} {k7:>5.1f} {whip:>6.2f} {wsign}{pwar:>5.2f}")

    pitch_path = export_csv(pitch_rows, pitch_cols, "pitching_war.csv")
    print(f"\n  Exported: {pitch_path} ({len(pitch_rows)} pitchers)")

    # ==========================================================
    # Combined WAR Leaderboard
    # ==========================================================
    print("\n" + "=" * 60)
    print("  TOP 30 PLAYERS BY TOTAL WAR")
    print("=" * 60 + "\n")

    comb_sql = read_sql("06_combined_war.sql")
    comb_rows, comb_cols = execute_query(conn, comb_sql)

    cci = {name: idx for idx, name in enumerate(comb_cols)}
    print(f"  {'#':>3s}  {'Name':<24s} {'Team':<16s} "
          f"{'PA':>4s} {'IP':>6s} {'bWAR':>6s} {'pWAR':>6s} {'Total':>6s}")
    print(f"  {'-' * 80}")

    for i, row in enumerate(comb_rows[:30]):
        name = (row[cci["player_name"]] or "")[:23]
        team_name = (row[cci.get("team_name", cci.get("team_id"))] or "")[:15]
        pa = row[cci["pa"]] or 0
        ip = row[cci["ip"]] or 0
        bwar = row[cci["batting_war"]] or 0
        pwar = row[cci["pitching_war"]] or 0
        twar = row[cci["total_war"]] or 0
        bs = "+" if bwar >= 0 else ""
        ps = "+" if pwar >= 0 else ""
        ts = "+" if twar >= 0 else ""
        print(f"  {i+1:>3d}  {name:<24s} {team_name:<16s} "
              f"{pa:>4d} {ip:>6.1f} {bs}{bwar:>5.2f} {ps}{pwar:>5.2f} {ts}{twar:>5.2f}")

    comb_path = export_csv(comb_rows, comb_cols, "war_leaderboard.csv")
    print(f"\n  Exported: {comb_path} ({len(comb_rows)} players)")

    # ==========================================================
    # Team WAR vs Wins Validation
    # ==========================================================
    print("\n" + "=" * 60)
    print("  TEAM WAR vs ACTUAL WINS")
    print("=" * 60 + "\n")

    team_sql = read_sql("07_team_war_validation.sql")
    team_rows, team_cols = execute_query(conn, team_sql)

    ti = {name: idx for idx, name in enumerate(team_cols)}
    print(f"  {'Team':<20s} {'Conf':<8s} {'W':>3s}-{'L':<3s} "
          f"{'WPct':>5s} {'bWAR':>7s} {'pWAR':>7s} {'Total':>7s}")
    print(f"  {'-' * 70}")

    # Separate P5 teams (known conference) for R² calculation
    p5_war_pg = []
    p5_wpct = []
    p5_war = []
    p5_wins = []

    for row in team_rows:
        team_name = (row[ti.get("team_name", ti.get("team_id"))] or "")[:19]
        conf = (row[ti["conference"]] or "")[:7]
        wins = row[ti["wins"]] or 0
        losses = row[ti["losses"]] or 0
        wpct = row[ti["win_pct"]] or 0
        bwar = row[ti["team_batting_war"]] or 0
        pwar = row[ti["team_pitching_war"]] or 0
        twar = row[ti["team_total_war"]] or 0
        war_pg = row[ti["war_per_game"]] or 0

        is_p5 = conf not in ("Unknown", "")
        if is_p5:
            p5_war_pg.append(war_pg)
            p5_wpct.append(wpct)
            p5_war.append(twar)
            p5_wins.append(wins)

        print(f"  {team_name:<20s} {conf:<8s} {wins:>3d}-{losses:<3d} "
              f"{wpct:>5.3f} {bwar:>+7.1f} {pwar:>+7.1f} {twar:>+7.1f}"
              + ("" if is_p5 else "  *"))

    # Compute R²
    if len(p5_war_pg) >= 3:
        r2_wpg = compute_r_squared(p5_war_pg, p5_wpct)
        r2_raw = compute_r_squared(p5_war, p5_wins)
        print(f"\n  R2 WAR/game vs WPct (P5, n={len(p5_war_pg)}): {r2_wpg:.3f}")
        print(f"  R2 total WAR vs Wins (P5, n={len(p5_war)}):  {r2_raw:.3f}")
        print(f"  (* = non-P5 opponent, excluded from R2)")

    team_path = export_csv(team_rows, team_cols, "team_war_vs_wins.csv")
    print(f"  Exported: {team_path}")

    conn.close()
    print("\nDone.\n")


if __name__ == "__main__":
    main()
