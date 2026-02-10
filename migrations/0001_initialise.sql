-- Migration number: 0001 	 2026-02-04T04:05:32.175Z
PRAGMA defer_foreign_keys = on;

CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  discord_id TEXT UNIQUE,
  created_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS servers (
  id INTEGER PRIMARY KEY,
  hostname TEXT UNIQUE,
  label TEXT UNIQUE,
  keystring TEXT UNIQUE,
  players_online INT,
  created_at INTEGER DEFAULT (unixepoch()),
  updated_at INTEGER DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS server_operators (
  server_id INTEGER,
  user_id TEXT,
  PRIMARY KEY (server_id, user_id),

  FOREIGN KEY (server_id) REFERENCES servers(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(discord_id) ON DELETE CASCADE
);
