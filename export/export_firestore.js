/**
 * export_firestore.js — Export NCAA Softball game data from Firestore to CSV
 *
 * Queries the `games` collection for NCAASB final games, applies the same
 * deduplication fingerprint as softballPlayerWAR.js, and writes:
 *   - data/games.csv
 *   - data/teams.csv
 *   - data/player_game_hitting.csv
 *   - data/player_game_pitching.csv
 *
 * Also copies the WAR lookup JSON as ground truth for validation.
 *
 * Usage:
 *   cd beacon_app/beacon/functions && node ../../../ncaa-softball-sql/export/export_firestore.js [seasonYear]
 */

import { getDb } from "../../beacon_app/beacon/functions/firebaseAdmin.js";
import { NCAASB_POWER5_TEAMS } from "../../beacon_app/beacon/functions/ncaasoftball/data/ncaasb_power5_teams.js";
import { writeFileSync, copyFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = join(__dirname, "..", "data");

const seasonYear = parseInt(process.argv[2] || "2026");

// ── Player name cleaning (matches softballPlayerWAR.js) ──
function cleanPlayerName(raw) {
  let name = (raw || "").trim();
  name = name.replace(/^\d+-?\d*\)\s*/, "");
  name = name.replace(/\s*\([WLS].*$/i, "");
  if (/^[A-Za-z'-]+,\s+[A-Za-z'-]+$/.test(name)) {
    const parts = name.split(",").map(s => s.trim());
    name = parts[1] + " " + parts[0];
  }
  return name.trim();
}

function makePlayerKey(teamId, cleanName) {
  return teamId + "_" + cleanName.toLowerCase().replace(/[^a-z]/g, "");
}

// Resolve primary fielding position from compound positions like "ph/ss"
function resolvePosition(raw) {
  const r = (raw || "util").toLowerCase().trim();
  const parts = r.split("/").map(s => s.trim()).filter(Boolean);
  const fieldingPositions = new Set(["c", "1b", "2b", "3b", "ss", "lf", "cf", "rf", "p", "dp", "dh"]);
  for (const part of parts) {
    if (fieldingPositions.has(part)) return part;
  }
  if (parts.every(p => p === "ph" || p === "pr")) return "util";
  return parts[0] || "util";
}

// ── Team ID normalization ──
// Firestore playerStats use raw team IDs that may differ from the canonical
// registry IDs. Build a normalization map from the registry + known variants.
const TEAM_ID_ALIASES = {};
for (const t of NCAASB_POWER5_TEAMS) {
  // Map the short name form to canonical ID
  const shortId = "ncaasb_" + t.name.toLowerCase().replace(/[^a-z0-9]/g, "-").replace(/-+/g, "-");
  if (shortId !== t.id) TEAM_ID_ALIASES[shortId] = t.id;
}
// Manual overrides for known variants in Firestore data
Object.assign(TEAM_ID_ALIASES, {
  "ncaasb_florida-state":     "ncaasb_florida-st",
  "ncaasb_mississippi-state": "ncaasb_mississippi-st",
  "ncaasb_oklahoma-state":    "ncaasb_oklahoma-st",
  "ncaasb_ohio-state":        "ncaasb_ohio-st",
  "ncaasb_oklahoma-sooners":  "ncaasb_oklahoma",
  "ncaasb_pitt":              "ncaasb_pittsburgh",
  "ncaasb_penn-state":        "ncaasb_penn-st",
  "ncaasb_michigan-st":       "ncaasb_michigan-state",
  "ncaasb_nc-state":          "ncaasb_north-carolina-state",
  "ncaasb_iowa-state":        "ncaasb_iowa-st",
  "ncaasb_cal":               "ncaasb_california",
  "ncaasb_arizona-st":        "ncaasb_arizona-state",
  "ncaasb_st-johns":          "ncaasb_st-johns-ny",
});

function normalizeTeamId(rawId) {
  return TEAM_ID_ALIASES[rawId] || rawId;
}

// Escape CSV field
function csvField(val) {
  if (val === null || val === undefined) return "";
  const s = String(val);
  if (s.includes(",") || s.includes('"') || s.includes("\n")) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

function csvRow(fields) {
  return fields.map(csvField).join(",");
}

async function run() {
  const db = getDb();

  console.log(`\nExporting NCAASB data for season ${seasonYear}...\n`);

  // ── Query all final games ──
  const gamesSnap = await db.collection("games")
    .where("sport", "==", "NCAASB")
    .where("seasonYear", "==", seasonYear)
    .where("status", "==", "final")
    .get();

  const allGames = gamesSnap.docs.map(d => ({ id: d.id, ...d.data() }));
  console.log(`Found ${allGames.length} final games`);

  // ── Dedup (same fingerprint as softballPlayerWAR.js) ──
  const fingerprints = new Map();
  const games = allGames.filter(game => {
    const tids = (game.teamIds || []).slice().sort();
    const scores = game.scores || {};
    const scoreStr = tids.map(id => scores[id] || 0).join("-");
    const hitterLines = [];
    for (const [, ps] of Object.entries(game.playerStats || {})) {
      if (ps.statType === "hitting") {
        hitterLines.push(`${ps.ab||0}-${ps.r||0}-${ps.h||0}-${ps.rbi||0}-${ps.bb||0}-${ps.so||0}`);
      }
    }
    hitterLines.sort();
    const fp = `${tids.join("|")}::${scoreStr}::${hitterLines.join("|")}`;
    if (fingerprints.has(fp)) return false;
    fingerprints.set(fp, game.id);
    return true;
  });

  if (allGames.length !== games.length) {
    console.log(`Dedup: skipped ${allGames.length - games.length} phantom duplicates`);
  }
  console.log(`Using ${games.length} unique games\n`);

  // ── Build team lookup from registry ──
  const teamMap = {};
  for (const t of NCAASB_POWER5_TEAMS) {
    teamMap[t.id] = { team_id: t.id, team_name: t.name, conference: t.conference };
  }

  // ── Process games into CSV rows ──
  const gameRows = [];
  const hittingRows = [];
  const pitchingRows = [];
  const seenTeams = new Set();

  for (const game of games) {
    const { playerStats, scores } = game;
    if (!playerStats || !scores) continue;

    const homeTeamId = normalizeTeamId(game.homeTeamId || "");
    const awayTeamId = normalizeTeamId(game.awayTeamId || "");
    // Scores are keyed by the raw (unnormalized) team IDs in Firestore
    const homeScore = scores[game.homeTeamId] || scores[homeTeamId] || 0;
    const awayScore = scores[game.awayTeamId] || scores[awayTeamId] || 0;
    const gameDate = game.gameDateISO || "";

    gameRows.push([game.id, seasonYear, gameDate, homeTeamId, awayTeamId, homeScore, awayScore]);
    seenTeams.add(homeTeamId);
    seenTeams.add(awayTeamId);

    // Group entries by cleaned player key within this game (same merge as softballPlayerWAR.js)
    const gameEntries = {};

    for (const [key, ps] of Object.entries(playerStats)) {
      if (!ps.teamId) continue;
      const normTeamId = normalizeTeamId(ps.teamId);
      const rawName = ps.playerName || ps.playerId || "unknown";
      const cleanName = cleanPlayerName(rawName);
      if (!cleanName) continue;
      const pKey = makePlayerKey(normTeamId, cleanName);

      if (!gameEntries[pKey]) {
        gameEntries[pKey] = { teamId: normTeamId, cleanName, hitting: [], pitching: [] };
      }
      if (cleanName.length > gameEntries[pKey].cleanName.length) {
        gameEntries[pKey].cleanName = cleanName;
      }

      if (ps.statType === "hitting") gameEntries[pKey].hitting.push(ps);
      else if (ps.statType === "pitching") gameEntries[pKey].pitching.push(ps);
    }

    // Flatten to CSV rows
    for (const [pKey, gpe] of Object.entries(gameEntries)) {
      // Hitting
      for (const ps of gpe.hitting) {
        const pos = resolvePosition((ps.position || "").toLowerCase());
        hittingRows.push([
          game.id, pKey, gpe.teamId, gpe.cleanName, pos,
          ps.ab || 0, ps.r || 0, ps.h || 0,
          ps.doubles || 0, ps.triples || 0, ps.hr || 0,
          ps.rbi || 0, ps.bb || 0, ps.hbp || 0, ps.so || 0,
          ps.sf || 0, ps.sh || 0, ps.sb || 0, ps.cs || 0,
        ]);
      }

      // Pitching: keep best entry per game (same dedup as softballPlayerWAR.js)
      if (gpe.pitching.length > 0) {
        const best = gpe.pitching.reduce((a, b) => {
          const scoreA = (a.h || 0) + (a.bb || 0) + (a.so || 0);
          const scoreB = (b.h || 0) + (b.bb || 0) + (b.so || 0);
          return scoreB > scoreA ? b : a;
        });

        const ip = best.ip || 0;
        const fullInnings = Math.floor(ip);
        const partialOuts = Math.round((ip - fullInnings) * 10);
        const totalOuts = fullInnings * 3 + partialOuts;
        const ipDecimal = totalOuts / 3;

        pitchingRows.push([
          game.id, pKey, gpe.teamId, gpe.cleanName,
          ipDecimal, best.h || 0, best.r || 0, best.er || 0,
          best.bb || 0, best.so || 0, best.hr || 0,
          best.win ? 1 : 0, best.loss ? 1 : 0, best.save ? 1 : 0,
        ]);
      }
    }
  }

  // ── Write games.csv ──
  const gamesHeader = "game_id,season_year,game_date,home_team_id,away_team_id,home_score,away_score";
  const gamesCsv = [gamesHeader, ...gameRows.map(r => csvRow(r))].join("\n");
  writeFileSync(join(DATA_DIR, "games.csv"), gamesCsv);
  console.log(`Wrote games.csv (${gameRows.length} rows)`);

  // ── Write teams.csv ──
  const teamRows = [];
  for (const tid of seenTeams) {
    if (teamMap[tid]) {
      teamRows.push([teamMap[tid].team_id, teamMap[tid].team_name, teamMap[tid].conference]);
    } else {
      // Unknown team encountered in game data
      const shortName = tid.replace("ncaasb_", "");
      teamRows.push([tid, shortName, "Unknown"]);
    }
  }
  const teamsHeader = "team_id,team_name,conference";
  const teamsCsv = [teamsHeader, ...teamRows.map(r => csvRow(r))].join("\n");
  writeFileSync(join(DATA_DIR, "teams.csv"), teamsCsv);
  console.log(`Wrote teams.csv (${teamRows.length} rows)`);

  // ── Write player_game_hitting.csv ──
  const hitHeader = "game_id,player_id,team_id,player_name,position,ab,r,h,doubles,triples,hr,rbi,bb,hbp,so,sf,sh,sb,cs";
  const hitCsv = [hitHeader, ...hittingRows.map(r => csvRow(r))].join("\n");
  writeFileSync(join(DATA_DIR, "player_game_hitting.csv"), hitCsv);
  console.log(`Wrote player_game_hitting.csv (${hittingRows.length} rows)`);

  // ── Write player_game_pitching.csv ──
  const pitchHeader = "game_id,player_id,team_id,player_name,ip,h,r,er,bb,so,hr,win,loss,save";
  const pitchCsv = [pitchHeader, ...pitchingRows.map(r => csvRow(r))].join("\n");
  writeFileSync(join(DATA_DIR, "player_game_pitching.csv"), pitchCsv);
  console.log(`Wrote player_game_pitching.csv (${pitchingRows.length} rows)`);

  // ── Copy war-lookup.json as ground truth ──
  const warLookupSrc = join(__dirname, "..", "..", "linedrive-analytics", "data", "war-lookup.json");
  const warLookupDst = join(DATA_DIR, "war_lookup_reference.json");
  if (existsSync(warLookupSrc)) {
    copyFileSync(warLookupSrc, warLookupDst);
    console.log(`\nCopied war-lookup.json as ground truth`);
  } else {
    console.log(`\nWarning: war-lookup.json not found at ${warLookupSrc}`);
  }

  console.log("\nExport complete.\n");
  process.exit(0);
}

run().catch(err => { console.error(err); process.exit(1); });
