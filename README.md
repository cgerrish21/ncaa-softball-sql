# NCAA Softball WAR — SQL Portfolio Project

A complete Wins Above Replacement (WAR) analytical system for NCAA Division I softball, implemented in SQL and Python. Reconstructs the same methodology as an existing JavaScript/Firestore pipeline, validated at R² = 0.947 against the JS pipeline's WAR values and R² = 0.836 for team WAR vs actual wins.

## Quick Start

```bash
# 1. Export data from Firestore (requires Firebase credentials)
cd beacon_app/beacon/functions && node ../../../ncaa-softball-sql/export/export_firestore.js 2026

# 2. Build SQLite database from CSVs
python scripts/create_db.py

# 3. Run WAR calculations and print leaderboards
python scripts/run_war.py

# 4. Validate against JS pipeline output
python scripts/validate.py
```

No external Python packages required — uses only `sqlite3`, `csv`, `json`, and `math` from the standard library.

## Methodology

### Batting WAR

```
K-weighted wOBA → wRAA → positional adjustment → replacement adjustment → ÷ RPW
```

| Component | Formula |
|-----------|---------|
| **wOBA** | `(0.50×BB + 0.50×HBP + 1.00×1B + 1.15×2B + 1.18×3B + 1.20×HR - 0.40×K) / PA` |
| **wRAA** | `((wOBA - lgWOBA) / 1.1387) × PA` |
| **Positional adj** | Position-specific runs/season, prorated by `PA / 130` |
| **Replacement adj** | `0.059 × PA` (derived from Pythagenpat at .310 WPct) |
| **RPW** | Pythagenpat: `(4 × avgRPG) / (totalRPG ^ 0.287)` |

Weights optimized via grid search + K penalty sweep. K penalty captures that strikeouts are worse than other outs (can't advance runners, can't produce sac flies). Combined R² = 78.6% (team WAR vs Win%).

### Pitching WAR

```
xERA (component regression) → runs saved vs replacement → ÷ RPW
```

| Component | Formula |
|-----------|---------|
| **xERA** | `-2.5788 + 0.5883×(nonHR-H/7) + 0.4587×(BB/7) + 1.4025×(HR/7)` |
| **Runs saved** | `(replacement_xERA - xERA) / 7 × IP` |
| **Replacement xERA** | `5.77` (from replacement WHIP 1.806, K/7 4.18) |

xERA model: IP-weighted OLS on 945 D1 pitchers (20+ IP), R² = 88.1%. Decomposes WHIP into hits/walks/HR with distinct ERA impacts. HR allowed is 2.4x as harmful as a non-HR hit.

### Runs Per Win

Pythagenpat formula: `exp = totalRPG^0.287`, `RPW = (4 × avgRPG) / exp ≈ 10.70`

## Schema

```
┌──────────────┐     ┌────────────────────────┐
│    teams     │     │         games           │
├──────────────┤     ├────────────────────────┤
│ team_id (PK) │◄──┐ │ game_id (PK)           │
│ team_name    │   ├─│ home_team_id (FK)       │
│ conference   │   ├─│ away_team_id (FK)       │
└──────────────┘   │ │ season_year             │
                   │ │ game_date               │
                   │ │ home_score, away_score   │
                   │ └────────────────────────┘
                   │
┌──────────────────────────────────────┐
│       player_game_hitting            │
├──────────────────────────────────────┤
│ id (PK)                              │
│ game_id (FK) ────────────────────────│──► games
│ player_id                            │
│ team_id (FK) ────────────────────────│──► teams
│ player_name, position                │
│ ab, r, h, doubles, triples, hr       │
│ rbi, bb, hbp, so, sf, sh, sb, cs    │
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│       player_game_pitching           │
├──────────────────────────────────────┤
│ id (PK)                              │
│ game_id (FK) ────────────────────────│──► games
│ player_id                            │
│ team_id (FK) ────────────────────────│──► teams
│ player_name                          │
│ ip, h, r, er, bb, so, hr            │
│ win, loss, save                      │
└──────────────────────────────────────┘
```

Views aggregate game-level data into season totals:
- `player_season_batting` — PA, singles, rate stats, mode position
- `player_season_pitching` — ERA, WHIP, K/7, component rates for xERA
- `team_records` — W-L from game scores

## SQL Highlights

### Batting WAR (04_batting_war.sql)
Single query with 5 chained CTEs implementing the complete formula. Window functions rank players within position groups.

### Pitching WAR (05_pitching_war.sql)
CTE chain computing decomposed component rates, xERA regression, and runs saved above replacement.

### Team Validation (07_team_war_validation.sql)
Aggregates all player WAR by team, joins to win-loss records. R² between team WAR and actual win percentage validates the model.

### Advanced Queries (08_advanced_queries.sql)
- Conference strength rankings with `RANK() OVER`
- Two-way player value (COALESCE batting + pitching)
- ERA vs xERA luck analysis
- Positional scarcity with `PERCENT_RANK` and `NTILE`
- Replacement-level distribution by position

## Key Results (2026 Season)

| Metric | Value |
|--------|-------|
| Players analyzed | 2,612 (1,175 matched to JS pipeline) |
| League wOBA (K-weighted) | 0.262 |
| League ERA | 5.01 |
| League R/G | 5.28 |
| Runs per Win (Pythagenpat) | 10.65 |
| Top batter | Jordan Woolery (UCLA) +5.60 WAR |
| Top pitcher | Jordy Frahm (Nebraska) +14.45 pWAR |
| Team WAR vs Wins R² | 0.836 (65 P5 teams) |

### Validation vs JS Pipeline

| Metric | Value |
|--------|-------|
| R² (Total WAR) | 0.947 |
| R² (Batting WAR) | 0.959 |
| R² (Pitching WAR) | 0.956 |
| Mean absolute diff | 0.27 |
| Within +/-0.50 | 82.9% |
| Players matched | 1,175 / 1,187 (99.0%) |

## Project Structure

```
ncaa-softball-sql/
├── README.md
├── requirements.txt
├── data/                          # Exported from Firestore
│   ├── games.csv
│   ├── player_game_hitting.csv
│   ├── player_game_pitching.csv
│   ├── teams.csv
│   └── war_lookup_reference.json  # JS pipeline ground truth
├── export/
│   └── export_firestore.js        # Firestore → CSV exporter
├── sql/
│   ├── 01_schema.sql              # Tables, FKs, indexes
│   ├── 02_views.sql               # Season aggregation views
│   ├── 03_league_averages.sql     # League baselines
│   ├── 04_batting_war.sql         # Batting WAR (5-CTE chain)
│   ├── 05_pitching_war.sql        # Pitching WAR (xERA model)
│   ├── 06_combined_war.sql        # Unified leaderboard
│   ├── 07_team_war_validation.sql # Team WAR vs wins
│   └── 08_advanced_queries.sql    # Portfolio showcase queries
├── scripts/
│   ├── create_db.py               # CSV → SQLite loader
│   ├── run_war.py                 # Execute queries, print results
│   └── validate.py                # Compare SQL vs JS pipeline
└── output/
    ├── war_leaderboard.csv
    └── team_war_vs_wins.csv
```
