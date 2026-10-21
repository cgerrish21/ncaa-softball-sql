-- 05_pitching_war.sql — xERA-based pitching WAR
--
-- CTE chain: raw stats → component rates → xERA model → runs saved → WAR
--
-- xERA model (decomposed, from softballWARConfig.js):
--   xERA = -2.5788 + 0.5883 * nonHR-H/7 + 0.4587 * BB/7 + 1.4025 * HR/7
--   Trained on 945 D1 pitchers (20+ IP), IP-weighted OLS, R² = 88.1%
--
-- Replacement xERA derived from replacement component rates:
--   nonHR-H/7 = 7.68, BB/7 = 3.75, HR/7 = 1.20
--   → Replacement xERA = -2.5788 + 0.5883*7.68 + 0.4587*3.75 + 1.4025*1.20 = 5.77

WITH rpw AS (
    -- Runs Per Win via Pythagenpat (same as batting WAR)
    SELECT
        CAST(SUM(home_score) + SUM(away_score) AS REAL) / (COUNT(*) * 2) AS avg_rpg,
        (4.0 * (CAST(SUM(home_score) + SUM(away_score) AS REAL) / (COUNT(*) * 2)))
        / POWER(
            (CAST(SUM(home_score) + SUM(away_score) AS REAL) / COUNT(*)),
            0.287
          ) AS runs_per_win
    FROM games
),

pitcher_rates AS (
    -- Component rates for xERA model
    SELECT
        p.player_id,
        p.team_id,
        p.player_name,
        p.games,
        p.ip,
        p.h,
        p.er,
        p.bb,
        p.so,
        p.hr,
        p.wins,
        p.losses,
        p.saves,
        p.era,
        p.whip,
        p.k7,
        p.nonhr_h7,
        p.bb7,
        p.hr7,
        -- xERA = -2.5788 + 0.5883 * nonHR-H/7 + 0.4587 * BB/7 + 1.4025 * HR/7
        -2.5788 + 0.5883 * p.nonhr_h7 + 0.4587 * p.bb7 + 1.4025 * p.hr7 AS xera
    FROM player_season_pitching p
    WHERE p.ip >= 5  -- minimum 5 IP to qualify (same as JS pipeline)
),

replacement AS (
    -- Replacement-level xERA from config constants
    -- nonHR-H/7=7.68, BB/7=3.75, HR/7=1.20
    SELECT
        -2.5788 + 0.5883 * 7.68 + 0.4587 * 3.75 + 1.4025 * 1.20 AS repl_xera
)

SELECT
    pr.player_id,
    pr.team_id,
    t.team_name,
    t.conference,
    pr.player_name,
    pr.games,
    pr.ip,
    pr.h        AS hits_allowed,
    pr.er,
    pr.bb       AS walks,
    pr.so       AS strikeouts,
    pr.hr       AS hr_allowed,
    pr.wins,
    pr.losses,
    pr.saves,
    ROUND(pr.era, 2)    AS era,
    ROUND(pr.whip, 2)   AS whip,
    ROUND(pr.k7, 1)     AS k7,
    ROUND(pr.nonhr_h7, 2) AS nonhr_h7,
    ROUND(pr.bb7, 2)    AS bb7,
    ROUND(pr.hr7, 2)    AS hr7,
    ROUND(pr.xera, 2)   AS xera,
    ROUND(rep.repl_xera, 2) AS repl_xera,

    -- Runs saved above replacement
    -- runsSaved = (repl_xERA - xERA) / 7 * IP
    ROUND((rep.repl_xera - pr.xera) / 7.0 * pr.ip, 2) AS runs_saved,

    -- Pitching WAR = runs_saved / RPW
    ROUND(
        ((rep.repl_xera - pr.xera) / 7.0 * pr.ip) / rpw.runs_per_win,
    2) AS pitching_war,

    ROUND(rpw.runs_per_win, 2) AS rpw

FROM pitcher_rates pr
CROSS JOIN rpw
CROSS JOIN replacement rep
LEFT JOIN teams t ON t.team_id = pr.team_id
ORDER BY pitching_war DESC;
