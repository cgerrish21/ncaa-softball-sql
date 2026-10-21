-- 04_batting_war.sql — Full batting WAR calculation
--
-- Single query with 5 chained CTEs implementing the complete batting WAR formula.
-- All constants from softballWARConfig.js (single source of truth).
--
-- Methodology:
--   wOBA (K-weighted) → wRAA → positional adj → replacement adj → ÷ RPW = WAR

WITH league_totals AS (
    -- Step 1: League-wide batting totals for wOBA baseline
    SELECT
        SUM(pa)       AS lg_pa,
        SUM(singles)  AS lg_1b,
        SUM(doubles)  AS lg_2b,
        SUM(triples)  AS lg_3b,
        SUM(hr)       AS lg_hr,
        SUM(bb)       AS lg_bb,
        SUM(hbp)      AS lg_hbp,
        SUM(so)       AS lg_k,
        SUM(r)        AS lg_r,
        -- K-weighted league wOBA
        (0.50 * SUM(bb) + 0.50 * SUM(hbp) + 1.00 * SUM(singles)
         + 1.15 * SUM(doubles) + 1.18 * SUM(triples) + 1.20 * SUM(hr)
         + (-0.40) * SUM(so))
        / CAST(SUM(pa) AS REAL) AS lg_woba
    FROM player_season_batting
),

rpw AS (
    -- Step 2: Runs Per Win via Pythagenpat
    -- RPW = (4 * avgRPG) / (totalRPG ^ 0.287)
    SELECT
        CAST(SUM(home_score) + SUM(away_score) AS REAL) / (COUNT(*) * 2) AS avg_rpg,
        (4.0 * (CAST(SUM(home_score) + SUM(away_score) AS REAL) / (COUNT(*) * 2)))
        / POWER(
            (CAST(SUM(home_score) + SUM(away_score) AS REAL) / COUNT(*)),
            0.287
          ) AS runs_per_win
    FROM games
),

player_woba AS (
    -- Step 3: Per-player K-weighted wOBA
    SELECT
        b.player_id,
        b.team_id,
        b.player_name,
        b.position,
        b.games,
        b.pa,
        b.ab,
        b.h,
        b.hr,
        b.bb,
        b.hbp,
        b.so,
        b.sb,
        b.singles,
        b.doubles,
        b.triples,
        b.r,
        b.rbi,
        -- Player wOBA
        CASE WHEN b.pa > 0 THEN
            (0.50 * b.bb + 0.50 * b.hbp + 1.00 * b.singles
             + 1.15 * b.doubles + 1.18 * b.triples + 1.20 * b.hr
             + (-0.40) * b.so)
            / CAST(b.pa AS REAL)
        ELSE 0 END AS woba,
        -- Traditional slash line
        CASE WHEN b.ab > 0 THEN CAST(b.h AS REAL) / b.ab ELSE 0 END AS avg,
        CASE WHEN b.pa > 0 THEN CAST(b.h + b.bb + b.hbp AS REAL) / b.pa ELSE 0 END AS obp,
        CASE WHEN b.ab > 0 THEN
            CAST(b.singles + 2*b.doubles + 3*b.triples + 4*b.hr AS REAL) / b.ab
        ELSE 0 END AS slg
    FROM player_season_batting b
    WHERE b.pa >= 30  -- minimum PA threshold
),

positional_adj AS (
    -- Step 4: Positional adjustments (runs per full season ~130 PA, prorated)
    -- Values from softballWARConfig.js POSITIONAL_ADJ_PER_SEASON
    SELECT player_id, team_id,
        CASE position
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
            ELSE              -2.73  -- util/unknown default
        END AS pos_adj_per_season
    FROM player_woba
)

-- Step 5: Final WAR = (wRAA + pos_adj + repl_adj) / RPW
SELECT
    pw.player_id,
    pw.team_id,
    t.team_name,
    t.conference,
    pw.player_name,
    pw.position,
    pw.games,
    pw.pa,
    pw.ab,
    pw.h,
    pw.hr,
    pw.bb,
    pw.sb,
    pw.r,
    pw.rbi,
    ROUND(pw.avg, 3)  AS avg,
    ROUND(pw.obp, 3)  AS obp,
    ROUND(pw.slg, 3)  AS slg,
    ROUND(pw.woba, 3) AS woba,
    ROUND(lt.lg_woba, 3) AS lg_woba,

    -- wRAA = ((wOBA - lgWOBA) / wOBA_scale) * PA
    -- wOBA_scale = 1.1387
    ROUND(((pw.woba - lt.lg_woba) / 1.1387) * pw.pa, 2) AS wraa,

    -- Positional adjustment prorated by PA (full season = 130 PA)
    ROUND(pa.pos_adj_per_season * (CAST(pw.pa AS REAL) / 130.0), 2) AS pos_adj,

    -- Replacement level adjustment = 0.059 runs/PA * PA
    ROUND(0.059 * pw.pa, 2) AS repl_adj,

    -- Batting WAR
    ROUND(
        (((pw.woba - lt.lg_woba) / 1.1387) * pw.pa    -- wRAA
         + pa.pos_adj_per_season * (CAST(pw.pa AS REAL) / 130.0) -- pos adj
         + 0.059 * pw.pa)                               -- repl adj
        / rpw.runs_per_win,
    2) AS batting_war,

    ROUND(rpw.runs_per_win, 2) AS rpw,

    -- Positional rank
    ROW_NUMBER() OVER (
        PARTITION BY pw.position
        ORDER BY
            (((pw.woba - lt.lg_woba) / 1.1387) * pw.pa
             + pa.pos_adj_per_season * (CAST(pw.pa AS REAL) / 130.0)
             + 0.059 * pw.pa)
            / rpw.runs_per_win
        DESC
    ) AS pos_rank

FROM player_woba pw
CROSS JOIN league_totals lt
CROSS JOIN rpw
JOIN positional_adj pa ON pa.player_id = pw.player_id AND pa.team_id = pw.team_id
LEFT JOIN teams t ON t.team_id = pw.team_id
ORDER BY batting_war DESC;
