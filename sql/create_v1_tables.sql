PRAGMA defer_foreign_keys = on;

CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  discord_id TEXT UNIQUE,
  created_at INTEGER DEFAULT unixepoch()
);

CREATE TABLE IF NOT EXISTS servers (
  id INTEGER PRIMARY KEY,
  hostname TEXT,
  players_online INT,
  created_at INTEGER DEFAULT unixepoch(),
  updated_at INTEGER DEFAULT unixepoch()
);

CREATE TABLE IF NOT EXISTS keys (
  id INTEGER PRIMARY KEY,
  keystring TEXT UNIQUE,
  server_id INTEGER,

  FOREIGN KEY(server_with_key) REFERENCES servers(id)
);
