-- 07_team_war_validation.sql — Team WAR vs actual wins (R² validation)
--
-- Aggregates player WAR by team, joins to team_records, and outputs
-- the data needed to compute correlation. Target: R² ≈ 0.900.

WITH league_totals AS (
    SELECT
        (0.50 * SUM(bb) + 0.50 * SUM(hbp) + 1.00 * SUM(singles)
         + 1.15 * SUM(doubles) + 1.18 * SUM(triples) + 1.20 * SUM(hr)
         + (-0.40) * SUM(so))
        / CAST(SUM(pa) AS REAL) AS lg_woba
    FROM player_season_batting
),

rpw AS (
    SELECT
        (4.0 * (CAST(SUM(home_score) + SUM(away_score) AS REAL) / (COUNT(*) * 2)))
        / POWER(
            (CAST(SUM(home_score) + SUM(away_score) AS REAL) / COUNT(*)),
            0.287
          ) AS runs_per_win
    FROM games
),

replacement AS (
    SELECT -2.5788 + 0.5883 * 7.68 + 0.4587 * 3.75 + 1.4025 * 1.20 AS repl_xera
),

-- Per-player batting WAR (all players, no minimum)
player_batting_war AS (
    SELECT
        b.player_id,
        b.team_id,
        CASE WHEN b.pa > 0 THEN
            (((0.50 * b.bb + 0.50 * b.hbp + 1.00 * b.singles
               + 1.15 * b.doubles + 1.18 * b.triples + 1.20 * b.hr
               + (-0.40) * b.so) / CAST(b.pa AS REAL)
              - lt.lg_woba) / 1.1387 * b.pa
             + CASE COALESCE(b.position, 'util')
                 WHEN 'p'    THEN  0.00
                 WHEN 'c'    THEN -1.63
                 WHEN 'ss'   THEN -2.78
                 WHEN '2b'   THEN -4.30
                 WHEN '3b'   THEN -1.48
                 WHEN 'cf'   THEN -2.21
                 WHEN 'lf'   THEN -3.73
                 WHEN 'rf'   THEN -4.22
                 WHEN '1b'   THEN -6.08
                 WHEN 'if'   THEN -2.78
                 WHEN 'of'   THEN -3.39
                 WHEN 'dp'   THEN -2.73
                 WHEN 'dh'   THEN -2.73
                 ELSE              -2.73
               END * (CAST(b.pa AS REAL) / 130.0)
             + 0.059 * b.pa)
            / rpw.runs_per_win
        ELSE 0 END AS batting_war
    FROM player_season_batting b
    CROSS JOIN league_totals lt
    CROSS JOIN rpw
),

-- Per-player pitching WAR
player_pitching_war AS (
    SELECT
        p.player_id,
        p.team_id,
        CASE WHEN p.ip >= 5 THEN
            ((rep.repl_xera - (-2.5788 + 0.5883 * p.nonhr_h7 + 0.4587 * p.bb7 + 1.4025 * p.hr7))
             / 7.0 * p.ip) / rpw.runs_per_win
        ELSE 0 END AS pitching_war
    FROM player_season_pitching p
    CROSS JOIN rpw
    CROSS JOIN replacement rep
),

-- Team WAR: sum all player contributions
team_war AS (
    SELECT
        team_id,
        SUM(batting_war) AS team_batting_war,
        0 AS team_pitching_war
    FROM player_batting_war
    GROUP BY team_id

    UNION ALL

    SELECT
        team_id,
        0 AS team_batting_war,
        SUM(pitching_war) AS team_pitching_war
    FROM player_pitching_war
    GROUP BY team_id
),

team_war_combined AS (
    SELECT
        team_id,
        SUM(team_batting_war)  AS team_batting_war,
        SUM(team_pitching_war) AS team_pitching_war,
        SUM(team_batting_war) + SUM(team_pitching_war) AS team_total_war
    FROM team_war
    GROUP BY team_id
)

SELECT
    tw.team_id,
    t.team_name,
    t.conference,
    tr.wins,
    tr.losses,
    tr.games_played,
    ROUND(tr.win_pct, 3) AS win_pct,
    ROUND(tw.team_batting_war, 2) AS team_batting_war,
    ROUND(tw.team_pitching_war, 2) AS team_pitching_war,
    ROUND(tw.team_total_war, 2) AS team_total_war
FROM team_war_combined tw
JOIN team_records tr ON tr.team_id = tw.team_id
LEFT JOIN teams t ON t.team_id = tw.team_id
ORDER BY tw.team_total_war DESC;
