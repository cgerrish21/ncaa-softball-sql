-- 02_views.sql — Season aggregation views
--
-- Aggregate game-level stats into season totals. These views are the
-- foundation for WAR calculations.

-- Player season batting: sum game-level stats, derive PA and singles.
-- Mode position = the position the player appeared at most often.
CREATE VIEW IF NOT EXISTS player_season_batting AS
SELECT
    h.player_id,
    h.team_id,
    MAX(h.player_name)                      AS player_name,
    -- Mode position: most frequent fielding position across games
    (
        SELECT position
        FROM player_game_hitting sub
        WHERE sub.player_id = h.player_id
          AND sub.team_id = h.team_id
          AND sub.position IS NOT NULL
          AND sub.position != ''
        GROUP BY position
        ORDER BY COUNT(*) DESC
        LIMIT 1
    )                                        AS position,
    COUNT(DISTINCT h.game_id)               AS games,
    SUM(h.ab)                               AS ab,
    SUM(h.h)                                AS h,
    SUM(h.doubles)                          AS doubles,
    SUM(h.triples)                          AS triples,
    SUM(h.hr)                               AS hr,
    SUM(h.h) - SUM(h.doubles)
        - SUM(h.triples) - SUM(h.hr)       AS singles,
    SUM(h.bb)                               AS bb,
    SUM(h.hbp)                              AS hbp,
    SUM(h.so)                               AS so,
    SUM(h.sf)                               AS sf,
    SUM(h.sh)                               AS sh,
    SUM(h.r)                                AS r,
    SUM(h.rbi)                              AS rbi,
    SUM(h.sb)                               AS sb,
    SUM(h.cs)                               AS cs,
    -- Plate appearances = AB + BB + HBP + SF + SH
    SUM(h.ab) + SUM(h.bb) + SUM(h.hbp)
        + SUM(h.sf) + SUM(h.sh)            AS pa
FROM player_game_hitting h
GROUP BY h.player_id, h.team_id;


-- Player season pitching: sum game-level stats, derive rate stats.
CREATE VIEW IF NOT EXISTS player_season_pitching AS
SELECT
    p.player_id,
    p.team_id,
    MAX(p.player_name)                      AS player_name,
    COUNT(DISTINCT p.game_id)               AS games,
    SUM(p.ip)                               AS ip,
    SUM(p.h)                                AS h,
    SUM(p.r)                                AS r,
    SUM(p.er)                               AS er,
    SUM(p.bb)                               AS bb,
    SUM(p.so)                               AS so,
    SUM(p.hr)                               AS hr,
    SUM(p.win)                              AS wins,
    SUM(p.loss)                             AS losses,
    SUM(p.save)                             AS saves,
    -- Rate stats
    CASE WHEN SUM(p.ip) > 0
         THEN (CAST(SUM(p.er) AS REAL) / SUM(p.ip)) * 7.0
         ELSE NULL END                      AS era,
    CASE WHEN SUM(p.ip) > 0
         THEN CAST(SUM(p.h) + SUM(p.bb) AS REAL) / SUM(p.ip)
         ELSE NULL END                      AS whip,
    CASE WHEN SUM(p.ip) > 0
         THEN (CAST(SUM(p.so) AS REAL) / SUM(p.ip)) * 7.0
         ELSE NULL END                      AS k7,
    -- Decomposed rates for xERA model
    CASE WHEN SUM(p.ip) > 0
         THEN (CAST(SUM(p.h) - SUM(p.hr) AS REAL) / SUM(p.ip)) * 7.0
         ELSE NULL END                      AS nonhr_h7,
    CASE WHEN SUM(p.ip) > 0
         THEN (CAST(SUM(p.bb) AS REAL) / SUM(p.ip)) * 7.0
         ELSE NULL END                      AS bb7,
    CASE WHEN SUM(p.ip) > 0
         THEN (CAST(SUM(p.hr) AS REAL) / SUM(p.ip)) * 7.0
         ELSE NULL END                      AS hr7
FROM player_game_pitching p
GROUP BY p.player_id, p.team_id;


-- Team records: derive W-L from game scores.
-- Uses UNION ALL to count each game from both team perspectives.
CREATE VIEW IF NOT EXISTS team_records AS
SELECT
    team_id,
    SUM(wins)   AS wins,
    SUM(losses) AS losses,
    COUNT(*)    AS games_played,
    CAST(SUM(wins) AS REAL) / COUNT(*) AS win_pct
FROM (
    -- Home team perspective
    SELECT
        home_team_id AS team_id,
        CASE WHEN home_score > away_score THEN 1 ELSE 0 END AS wins,
        CASE WHEN home_score < away_score THEN 1 ELSE 0 END AS losses
    FROM games

    UNION ALL

    -- Away team perspective
    SELECT
        away_team_id AS team_id,
        CASE WHEN away_score > home_score THEN 1 ELSE 0 END AS wins,
        CASE WHEN away_score < home_score THEN 1 ELSE 0 END AS losses
    FROM games
)
GROUP BY team_id;
