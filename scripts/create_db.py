"""
create_db.py — Create SQLite database from exported CSVs

Reads CSVs from data/, creates ncaa_softball.db, loads data,
and executes schema + views.

Usage:
    python scripts/create_db.py
"""

import csv
import math
import os
import sqlite3
import sys

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(PROJECT_DIR, "data")
SQL_DIR = os.path.join(PROJECT_DIR, "sql")
DB_PATH = os.path.join(PROJECT_DIR, "ncaa_softball.db")


def register_functions(conn):
    """Register custom functions that SQLite lacks natively."""
    conn.create_function("POWER", 2, lambda base, exp: math.pow(base, exp))


def execute_sql_file(conn, filename):
    """Execute a SQL file, handling multiple statements."""
    filepath = os.path.join(SQL_DIR, filename)
    with open(filepath, "r") as f:
        sql = f.read()
    conn.executescript(sql)


def load_csv(conn, table_name, csv_filename, columns, or_ignore=False):
    """Load a CSV file into a table."""
    filepath = os.path.join(DATA_DIR, csv_filename)
    if not os.path.exists(filepath):
        print(f"  WARNING: {csv_filename} not found, skipping")
        return 0

    placeholders = ", ".join(["?"] * len(columns))
    verb = "INSERT OR IGNORE" if or_ignore else "INSERT"
    insert_sql = f"{verb} INTO {table_name} ({', '.join(columns)}) VALUES ({placeholders})"

    count = 0
    with open(filepath, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            values = []
            for col in columns:
                val = row.get(col, "")
                # Type conversions
                if col in ("season_year", "home_score", "away_score",
                           "ab", "r", "h", "doubles", "triples", "hr",
                           "rbi", "bb", "hbp", "so", "sf", "sh", "sb", "cs",
                           "er", "win", "loss", "save"):
                    values.append(int(val) if val else 0)
                elif col == "ip":
                    values.append(float(val) if val else 0.0)
                else:
                    values.append(val)
            conn.execute(insert_sql, values)
            count += 1

    return count


def main():
    # Remove existing DB
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
        print(f"Removed existing {DB_PATH}")

    # Check data directory
    if not os.path.exists(DATA_DIR):
        print(f"ERROR: data/ directory not found at {DATA_DIR}")
        print("Run the Firestore export first: node export/export_firestore.js")
        sys.exit(1)

    conn = sqlite3.connect(DB_PATH)
    register_functions(conn)
    conn.execute("PRAGMA journal_mode=WAL")
    # FK enforcement off: historical Firestore data has some team ID
    # variants in playerStats (e.g., ncaasb_st-johns vs ncaasb_st-johns-ny)
    conn.execute("PRAGMA foreign_keys=OFF")

    # 1. Create schema
    print("\n--- Creating schema ---")
    execute_sql_file(conn, "01_schema.sql")
    print("  Tables and indexes created")

    # 2. Load data
    print("\n--- Loading data ---")

    teams_count = load_csv(conn, "teams", "teams.csv",
                           ["team_id", "team_name", "conference"],
                           or_ignore=True)
    print(f"  teams: {teams_count} rows")

    games_count = load_csv(conn, "games", "games.csv",
                           ["game_id", "season_year", "game_date",
                            "home_team_id", "away_team_id",
                            "home_score", "away_score"],
                           or_ignore=True)
    print(f"  games: {games_count} rows")

    hitting_count = load_csv(conn, "player_game_hitting",
                             "player_game_hitting.csv",
                             ["game_id", "player_id", "team_id",
                              "player_name", "position",
                              "ab", "r", "h", "doubles", "triples", "hr",
                              "rbi", "bb", "hbp", "so", "sf", "sh", "sb", "cs"])
    print(f"  player_game_hitting: {hitting_count} rows")

    pitching_count = load_csv(conn, "player_game_pitching",
                              "player_game_pitching.csv",
                              ["game_id", "player_id", "team_id",
                               "player_name", "ip",
                               "h", "r", "er", "bb", "so", "hr",
                               "win", "loss", "save"])
    print(f"  player_game_pitching: {pitching_count} rows")

    conn.commit()

    # 3. Create views
    print("\n--- Creating views ---")
    execute_sql_file(conn, "02_views.sql")
    print("  Views created")

    # 4. Verify
    print("\n--- Verification ---")
    for table in ["teams", "games", "player_game_hitting", "player_game_pitching"]:
        count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"  {table}: {count} rows")

    for view in ["player_season_batting", "player_season_pitching", "team_records"]:
        count = conn.execute(f"SELECT COUNT(*) FROM {view}").fetchone()[0]
        print(f"  {view}: {count} rows")

    conn.close()
    print(f"\nDatabase created: {DB_PATH}")
    print(f"Size: {os.path.getsize(DB_PATH) / 1024:.0f} KB\n")


if __name__ == "__main__":
    main()
