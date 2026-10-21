-- 06_combined_war.sql — Unified WAR leaderboard (batting + pitching)
--
-- Joins batting and pitching WAR for all players. Two-way players
-- get both components summed into total_war.
--
-- SQLite lacks FULL OUTER JOIN, so we use a union of all player keys
-- from both batting and pitching CTEs, then LEFT JOIN each back.

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

batting AS (
    SELECT
        b.player_id,
        b.team_id,
        b.player_name,
        b.position,
        b.games,
        b.pa,
        b.ab,
        b.h,
        CASE WHEN b.pa > 0 THEN
            (0.50 * b.bb + 0.50 * b.hbp + 1.00 * b.singles
             + 1.15 * b.doubles + 1.18 * b.triples + 1.20 * b.hr
             + (-0.40) * b.so) / CAST(b.pa AS REAL)
        ELSE 0 END AS woba,
        CASE WHEN b.ab > 0 THEN CAST(b.h AS REAL) / b.ab ELSE 0 END AS avg,
        CASE WHEN b.pa > 0 THEN CAST(b.h + b.bb + b.hbp AS REAL) / b.pa ELSE 0 END AS obp,
        CASE WHEN b.ab > 0 THEN
            CAST(b.singles + 2*b.doubles + 3*b.triples + 4*b.hr AS REAL) / b.ab
        ELSE 0 END AS slg,
        -- Batting WAR
        (((CASE WHEN b.pa > 0 THEN
            (0.50 * b.bb + 0.50 * b.hbp + 1.00 * b.singles
             + 1.15 * b.doubles + 1.18 * b.triples + 1.20 * b.hr
             + (-0.40) * b.so) / CAST(b.pa AS REAL)
          ELSE 0 END) - lt.lg_woba) / 1.1387 * b.pa
         + CASE b.position
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
        / rpw.runs_per_win AS batting_war
    FROM player_season_batting b
    CROSS JOIN league_totals lt
    CROSS JOIN rpw
    WHERE b.pa >= 30
),

pitching AS (
    SELECT
        p.player_id,
        p.team_id,
        p.player_name AS pitch_name,
        p.ip,
        p.era,
        p.whip,
        p.k7,
        -2.5788 + 0.5883 * p.nonhr_h7 + 0.4587 * p.bb7 + 1.4025 * p.hr7 AS xera,
        ((rep.repl_xera - (-2.5788 + 0.5883 * p.nonhr_h7 + 0.4587 * p.bb7 + 1.4025 * p.hr7))
         / 7.0 * p.ip) / rpw.runs_per_win AS pitching_war
    FROM player_season_pitching p
    CROSS JOIN rpw
    CROSS JOIN replacement rep
    WHERE p.ip >= 5
),

-- All unique player+team combinations from either batting or pitching
all_players AS (
    SELECT player_id, team_id FROM batting
    UNION
    SELECT player_id, team_id FROM pitching
)

SELECT
    ap.player_id,
    ap.team_id,
    t.team_name,
    t.conference,
    COALESCE(b.player_name, p.pitch_name) AS player_name,
    b.position,
    COALESCE(b.games, 0)                  AS games,
    COALESCE(b.pa, 0)                     AS pa,
    COALESCE(p.ip, 0)                     AS ip,
    ROUND(COALESCE(b.avg, 0), 3)          AS avg,
    ROUND(COALESCE(b.obp, 0), 3)          AS obp,
    ROUND(COALESCE(b.slg, 0), 3)          AS slg,
    ROUND(COALESCE(b.woba, 0), 3)         AS woba,
    ROUND(COALESCE(p.era, 0), 2)          AS era,
    ROUND(COALESCE(p.whip, 0), 2)         AS whip,
    ROUND(COALESCE(p.xera, 0), 2)         AS xera,
    ROUND(COALESCE(b.batting_war, 0), 2)  AS batting_war,
    ROUND(COALESCE(p.pitching_war, 0), 2) AS pitching_war,
    ROUND(COALESCE(b.batting_war, 0) + COALESCE(p.pitching_war, 0), 2) AS total_war
FROM all_players ap
LEFT JOIN batting b ON b.player_id = ap.player_id AND b.team_id = ap.team_id
LEFT JOIN pitching p ON p.player_id = ap.player_id AND p.team_id = ap.team_id
LEFT JOIN teams t ON t.team_id = ap.team_id
WHERE COALESCE(b.pa, 0) >= 30 OR COALESCE(p.ip, 0) >= 15
ORDER BY total_war DESC;
