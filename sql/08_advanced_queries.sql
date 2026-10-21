-- 08_advanced_queries.sql — Showcase queries for SQL portfolio
--
-- Demonstrates: window functions, CTEs, aggregation, CASE expressions,
-- PERCENT_RANK, NTILE, correlated subqueries.


-- ═══════════════════════════════════════════════════════════════
-- 1. Conference Strength Rankings
--    Aggregate WAR by conference, rank conferences by total and average.
-- ═══════════════════════════════════════════════════════════════

WITH league_totals AS (
    SELECT
        (0.50 * SUM(bb) + 0.50 * SUM(hbp) + 1.00 * SUM(singles)
         + 1.15 * SUM(doubles) + 1.18 * SUM(triples) + 1.20 * SUM(hr)
         + (-0.40) * SUM(so)) / CAST(SUM(pa) AS REAL) AS lg_woba
    FROM player_season_batting
),
rpw AS (
    SELECT (4.0 * (CAST(SUM(home_score) + SUM(away_score) AS REAL) / (COUNT(*) * 2)))
        / POWER((CAST(SUM(home_score) + SUM(away_score) AS REAL) / COUNT(*)), 0.287)
        AS runs_per_win
    FROM games
),
player_war AS (
    SELECT b.team_id,
        CASE WHEN b.pa > 0 THEN
            (((0.50*b.bb + 0.50*b.hbp + 1.00*b.singles + 1.15*b.doubles
               + 1.18*b.triples + 1.20*b.hr + (-0.40)*b.so) / CAST(b.pa AS REAL)
              - lt.lg_woba) / 1.1387 * b.pa
             + CASE COALESCE(b.position,'util')
                 WHEN 'p' THEN 0 WHEN 'c' THEN -1.63 WHEN 'ss' THEN -2.78
                 WHEN '2b' THEN -4.30 WHEN '3b' THEN -1.48 WHEN 'cf' THEN -2.21
                 WHEN 'lf' THEN -3.73 WHEN 'rf' THEN -4.22 WHEN '1b' THEN -6.08
                 WHEN 'dp' THEN -2.73 WHEN 'dh' THEN -2.73 ELSE -2.73
               END * (CAST(b.pa AS REAL) / 130.0)
             + 0.059 * b.pa) / rpw.runs_per_win
        ELSE 0 END AS war
    FROM player_season_batting b
    CROSS JOIN league_totals lt CROSS JOIN rpw
    WHERE b.pa >= 30
)
SELECT
    t.conference,
    COUNT(DISTINCT pw.team_id)  AS teams,
    COUNT(*)                     AS qualified_players,
    ROUND(SUM(pw.war), 1)       AS total_war,
    ROUND(AVG(pw.war), 2)       AS avg_war_per_player,
    ROUND(SUM(pw.war) / COUNT(DISTINCT pw.team_id), 1) AS avg_war_per_team,
    RANK() OVER (ORDER BY SUM(pw.war) / COUNT(DISTINCT pw.team_id) DESC) AS conf_rank
FROM player_war pw
JOIN teams t ON t.team_id = pw.team_id
GROUP BY t.conference
ORDER BY conf_rank;


-- ═══════════════════════════════════════════════════════════════
-- 2. Two-Way Player Value
--    Players with both significant batting and pitching contributions.
-- ═══════════════════════════════════════════════════════════════

WITH league_totals AS (
    SELECT (0.50*SUM(bb) + 0.50*SUM(hbp) + 1.00*SUM(singles) + 1.15*SUM(doubles)
            + 1.18*SUM(triples) + 1.20*SUM(hr) + (-0.40)*SUM(so))
           / CAST(SUM(pa) AS REAL) AS lg_woba
    FROM player_season_batting
),
rpw AS (
    SELECT (4.0*(CAST(SUM(home_score)+SUM(away_score) AS REAL)/(COUNT(*)*2)))
        / POWER((CAST(SUM(home_score)+SUM(away_score) AS REAL)/COUNT(*)), 0.287)
        AS runs_per_win FROM games
),
replacement AS (
    SELECT -2.5788 + 0.5883*7.68 + 0.4587*3.75 + 1.4025*1.20 AS repl_xera
),
bat AS (
    SELECT b.player_id, b.team_id, b.player_name, b.pa,
        (((0.50*b.bb + 0.50*b.hbp + 1.00*b.singles + 1.15*b.doubles
           + 1.18*b.triples + 1.20*b.hr + (-0.40)*b.so) / CAST(b.pa AS REAL)
          - lt.lg_woba) / 1.1387 * b.pa + 0.059*b.pa) / rpw.runs_per_win AS bwar
    FROM player_season_batting b
    CROSS JOIN league_totals lt CROSS JOIN rpw
    WHERE b.pa >= 30
),
pit AS (
    SELECT p.player_id, p.team_id, p.ip,
        ROUND(p.era, 2) AS era,
        ((rep.repl_xera - (-2.5788 + 0.5883*p.nonhr_h7 + 0.4587*p.bb7 + 1.4025*p.hr7))
         / 7.0 * p.ip) / rpw.runs_per_win AS pwar
    FROM player_season_pitching p
    CROSS JOIN rpw CROSS JOIN replacement rep
    WHERE p.ip >= 15
)
SELECT
    bat.player_name,
    t.team_name,
    bat.pa,
    pit.ip,
    pit.era,
    ROUND(bat.bwar, 2) AS batting_war,
    ROUND(pit.pwar, 2) AS pitching_war,
    ROUND(bat.bwar + pit.pwar, 2) AS total_war
FROM bat
JOIN pit ON bat.player_id = pit.player_id AND bat.team_id = pit.team_id
LEFT JOIN teams t ON t.team_id = bat.team_id
ORDER BY total_war DESC
LIMIT 20;


-- ═══════════════════════════════════════════════════════════════
-- 3. ERA vs xERA: Luck Analysis
--    Pitchers most outperforming or underperforming their expected ERA.
--    Large ERA - xERA gaps suggest luck (positive or negative).
-- ═══════════════════════════════════════════════════════════════

SELECT
    p.player_name,
    t.team_name,
    ROUND(p.ip, 1)  AS ip,
    ROUND(p.era, 2) AS era,
    ROUND(-2.5788 + 0.5883 * p.nonhr_h7 + 0.4587 * p.bb7 + 1.4025 * p.hr7, 2) AS xera,
    ROUND(p.era - (-2.5788 + 0.5883 * p.nonhr_h7 + 0.4587 * p.bb7 + 1.4025 * p.hr7), 2) AS era_minus_xera,
    ROUND(p.whip, 2) AS whip,
    ROUND(p.k7, 1)   AS k7,
    CASE
        WHEN p.era - (-2.5788 + 0.5883*p.nonhr_h7 + 0.4587*p.bb7 + 1.4025*p.hr7) < -1.0
            THEN 'Lucky (ERA well below xERA)'
        WHEN p.era - (-2.5788 + 0.5883*p.nonhr_h7 + 0.4587*p.bb7 + 1.4025*p.hr7) > 1.0
            THEN 'Unlucky (ERA well above xERA)'
        ELSE 'Neutral'
    END AS luck_label
FROM player_season_pitching p
LEFT JOIN teams t ON t.team_id = p.team_id
WHERE p.ip >= 40  -- qualified pitchers only
ORDER BY era_minus_xera ASC;


-- ═══════════════════════════════════════════════════════════════
-- 4. Positional Scarcity
--    PERCENT_RANK within position + NTILE tiers. Shows which positions
--    have the steepest talent drop-offs.
-- ═══════════════════════════════════════════════════════════════

WITH league_totals AS (
    SELECT (0.50*SUM(bb) + 0.50*SUM(hbp) + 1.00*SUM(singles) + 1.15*SUM(doubles)
            + 1.18*SUM(triples) + 1.20*SUM(hr) + (-0.40)*SUM(so))
           / CAST(SUM(pa) AS REAL) AS lg_woba
    FROM player_season_batting
),
rpw AS (
    SELECT (4.0*(CAST(SUM(home_score)+SUM(away_score) AS REAL)/(COUNT(*)*2)))
        / POWER((CAST(SUM(home_score)+SUM(away_score) AS REAL)/COUNT(*)), 0.287)
        AS runs_per_win FROM games
),
player_war AS (
    SELECT b.player_id, b.team_id, b.player_name, b.position, b.pa,
        CASE WHEN b.pa > 0 THEN
            (((0.50*b.bb + 0.50*b.hbp + 1.00*b.singles + 1.15*b.doubles
               + 1.18*b.triples + 1.20*b.hr + (-0.40)*b.so) / CAST(b.pa AS REAL)
              - lt.lg_woba) / 1.1387 * b.pa
             + CASE COALESCE(b.position,'util')
                 WHEN 'p' THEN 0 WHEN 'c' THEN -1.63 WHEN 'ss' THEN -2.78
                 WHEN '2b' THEN -4.30 WHEN '3b' THEN -1.48 WHEN 'cf' THEN -2.21
                 WHEN 'lf' THEN -3.73 WHEN 'rf' THEN -4.22 WHEN '1b' THEN -6.08
                 WHEN 'dp' THEN -2.73 WHEN 'dh' THEN -2.73 ELSE -2.73
               END * (CAST(b.pa AS REAL) / 130.0) + 0.059*b.pa)
            / rpw.runs_per_win
        ELSE 0 END AS war
    FROM player_season_batting b
    CROSS JOIN league_totals lt CROSS JOIN rpw
    WHERE b.pa >= 60  -- qualified regulars
      AND b.position IN ('c','1b','2b','3b','ss','lf','cf','rf','dp')
)
SELECT
    position,
    COUNT(*)               AS players,
    ROUND(AVG(war), 2)     AS avg_war,
    ROUND(MAX(war), 2)     AS max_war,
    ROUND(MIN(war), 2)     AS min_war,
    ROUND(MAX(war) - AVG(war), 2) AS top_vs_avg,
    -- Standard deviation proxy: range / 4
    ROUND((MAX(war) - MIN(war)) / 4.0, 2) AS war_spread
FROM player_war
GROUP BY position
ORDER BY avg_war DESC;


-- ═══════════════════════════════════════════════════════════════
-- 5. Replacement-Level Distribution
--    What percentage of players at each position are above/below
--    replacement level? Shows where talent pools are deepest.
-- ═══════════════════════════════════════════════════════════════

WITH league_totals AS (
    SELECT (0.50*SUM(bb) + 0.50*SUM(hbp) + 1.00*SUM(singles) + 1.15*SUM(doubles)
            + 1.18*SUM(triples) + 1.20*SUM(hr) + (-0.40)*SUM(so))
           / CAST(SUM(pa) AS REAL) AS lg_woba
    FROM player_season_batting
),
rpw AS (
    SELECT (4.0*(CAST(SUM(home_score)+SUM(away_score) AS REAL)/(COUNT(*)*2)))
        / POWER((CAST(SUM(home_score)+SUM(away_score) AS REAL)/COUNT(*)), 0.287)
        AS runs_per_win FROM games
),
player_war AS (
    SELECT b.player_id, b.position,
        CASE WHEN b.pa > 0 THEN
            (((0.50*b.bb + 0.50*b.hbp + 1.00*b.singles + 1.15*b.doubles
               + 1.18*b.triples + 1.20*b.hr + (-0.40)*b.so) / CAST(b.pa AS REAL)
              - lt.lg_woba) / 1.1387 * b.pa
             + CASE COALESCE(b.position,'util')
                 WHEN 'p' THEN 0 WHEN 'c' THEN -1.63 WHEN 'ss' THEN -2.78
                 WHEN '2b' THEN -4.30 WHEN '3b' THEN -1.48 WHEN 'cf' THEN -2.21
                 WHEN 'lf' THEN -3.73 WHEN 'rf' THEN -4.22 WHEN '1b' THEN -6.08
                 WHEN 'dp' THEN -2.73 WHEN 'dh' THEN -2.73 ELSE -2.73
               END * (CAST(b.pa AS REAL) / 130.0) + 0.059*b.pa)
            / rpw.runs_per_win
        ELSE 0 END AS war
    FROM player_season_batting b
    CROSS JOIN league_totals lt CROSS JOIN rpw
    WHERE b.pa >= 30
      AND b.position IN ('c','1b','2b','3b','ss','lf','cf','rf','dp','dh')
)
SELECT
    position,
    COUNT(*)                                           AS total_players,
    SUM(CASE WHEN war > 0 THEN 1 ELSE 0 END)          AS above_replacement,
    SUM(CASE WHEN war <= 0 THEN 1 ELSE 0 END)         AS below_replacement,
    ROUND(100.0 * SUM(CASE WHEN war > 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_above,
    ROUND(AVG(war), 2)                                 AS avg_war,
    -- NTILE quartile boundaries
    ROUND((SELECT war FROM player_war pw2
           WHERE pw2.position = player_war.position
           ORDER BY war DESC LIMIT 1 OFFSET (
               SELECT COUNT(*)/4 FROM player_war pw3 WHERE pw3.position = player_war.position
           )), 2) AS q1_threshold
FROM player_war
GROUP BY position
ORDER BY pct_above DESC;
