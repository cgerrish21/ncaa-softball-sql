-- 03_league_averages.sql — League-wide baselines for WAR calculation
--
-- Computes league wOBA, OBP, ERA, R/G, and Runs Per Win.
-- These feed into the batting and pitching WAR queries.

-- League batting totals
SELECT
    SUM(pa)       AS lg_pa,
    SUM(ab)       AS lg_ab,
    SUM(h)        AS lg_h,
    SUM(singles)  AS lg_1b,
    SUM(doubles)  AS lg_2b,
    SUM(triples)  AS lg_3b,
    SUM(hr)       AS lg_hr,
    SUM(bb)       AS lg_bb,
    SUM(hbp)      AS lg_hbp,
    SUM(so)       AS lg_k,
    SUM(sf)       AS lg_sf,
    SUM(r)        AS lg_r,

    -- K-weighted wOBA (production formula from softballWARConfig.js)
    -- BB=0.50, HBP=0.50, 1B=1.00, 2B=1.15, 3B=1.18, HR=1.20, K=-0.40
    (0.50 * SUM(bb) + 0.50 * SUM(hbp) + 1.00 * SUM(singles)
     + 1.15 * SUM(doubles) + 1.18 * SUM(triples) + 1.20 * SUM(hr)
     + (-0.40) * SUM(so))
    / CAST(SUM(pa) AS REAL)
    AS lg_woba,

    -- League OBP
    CAST(SUM(h) + SUM(bb) + SUM(hbp) AS REAL) / SUM(pa) AS lg_obp

FROM player_season_batting;

-- League pitching totals
SELECT
    SUM(ip)  AS lg_ip,
    SUM(er)  AS lg_er,
    CASE WHEN SUM(ip) > 0
         THEN (CAST(SUM(er) AS REAL) / SUM(ip)) * 7.0
         ELSE 0 END AS lg_era
FROM player_season_pitching;

-- League runs per game (from game scores, both teams)
SELECT
    CAST(SUM(home_score) + SUM(away_score) AS REAL) / (COUNT(*) * 2) AS lg_rpg,
    COUNT(*) AS total_games
FROM games;
