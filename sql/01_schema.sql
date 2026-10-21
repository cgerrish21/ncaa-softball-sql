-- 01_schema.sql — Normalized tables for NCAA Softball game data
--
-- Four tables at game-level grain. Foreign keys + indexes for
-- efficient aggregation in downstream WAR queries.

CREATE TABLE IF NOT EXISTS teams (
    team_id     TEXT PRIMARY KEY,
    team_name   TEXT NOT NULL,
    conference  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS games (
    game_id         TEXT PRIMARY KEY,
    season_year     INTEGER NOT NULL,
    game_date       TEXT,
    home_team_id    TEXT NOT NULL REFERENCES teams(team_id),
    away_team_id    TEXT NOT NULL REFERENCES teams(team_id),
    home_score      INTEGER NOT NULL,
    away_score      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS player_game_hitting (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id     TEXT NOT NULL REFERENCES games(game_id),
    player_id   TEXT NOT NULL,
    team_id     TEXT NOT NULL REFERENCES teams(team_id),
    player_name TEXT NOT NULL,
    position    TEXT,
    ab          INTEGER DEFAULT 0,
    r           INTEGER DEFAULT 0,
    h           INTEGER DEFAULT 0,
    doubles     INTEGER DEFAULT 0,
    triples     INTEGER DEFAULT 0,
    hr          INTEGER DEFAULT 0,
    rbi         INTEGER DEFAULT 0,
    bb          INTEGER DEFAULT 0,
    hbp         INTEGER DEFAULT 0,
    so          INTEGER DEFAULT 0,
    sf          INTEGER DEFAULT 0,
    sh          INTEGER DEFAULT 0,
    sb          INTEGER DEFAULT 0,
    cs          INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS player_game_pitching (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id     TEXT NOT NULL REFERENCES games(game_id),
    player_id   TEXT NOT NULL,
    team_id     TEXT NOT NULL REFERENCES teams(team_id),
    player_name TEXT NOT NULL,
    ip          REAL DEFAULT 0,
    h           INTEGER DEFAULT 0,
    r           INTEGER DEFAULT 0,
    er          INTEGER DEFAULT 0,
    bb          INTEGER DEFAULT 0,
    so          INTEGER DEFAULT 0,
    hr          INTEGER DEFAULT 0,
    win         INTEGER DEFAULT 0,
    loss        INTEGER DEFAULT 0,
    save        INTEGER DEFAULT 0
);

-- Indexes for aggregation queries
CREATE INDEX IF NOT EXISTS idx_hitting_player ON player_game_hitting(player_id);
CREATE INDEX IF NOT EXISTS idx_hitting_team ON player_game_hitting(team_id);
CREATE INDEX IF NOT EXISTS idx_hitting_game ON player_game_hitting(game_id);
CREATE INDEX IF NOT EXISTS idx_pitching_player ON player_game_pitching(player_id);
CREATE INDEX IF NOT EXISTS idx_pitching_team ON player_game_pitching(team_id);
CREATE INDEX IF NOT EXISTS idx_pitching_game ON player_game_pitching(game_id);
CREATE INDEX IF NOT EXISTS idx_games_season ON games(season_year);
