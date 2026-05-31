-- Users authenticated via OAuth (GitHub or Google).
CREATE TABLE users (
  id            TEXT PRIMARY KEY,             -- 'usr_<random>'
  provider      TEXT NOT NULL,                -- 'github' | 'google'
  provider_id   TEXT NOT NULL,                -- provider's stable user id
  username      TEXT NOT NULL UNIQUE,         -- derived from provider on first login
  email         TEXT NOT NULL,                -- lowercased; used for admin check
  avatar_url    TEXT,
  created_at    TEXT NOT NULL,                -- ISO8601
  UNIQUE(provider, provider_id)
);

CREATE INDEX idx_users_email ON users(email);

-- CLI/API tokens issued to users for `qube publish`.
CREATE TABLE tokens (
  id            TEXT PRIMARY KEY,             -- 'tok_<random>'
  user_id       TEXT NOT NULL REFERENCES users(id),
  hash          TEXT NOT NULL UNIQUE,         -- sha256(bearer token)
  scopes        TEXT NOT NULL,                -- comma list, e.g. 'publish'
  description   TEXT,
  created_at    TEXT NOT NULL,
  expires_at    TEXT,
  last_used_at  TEXT,
  revoked_at    TEXT
);

CREATE INDEX idx_tokens_user ON tokens(user_id);

-- Approved qubes (name registered, owner assigned).
CREATE TABLE qubes (
  name          TEXT PRIMARY KEY,             -- 'audio-filters' or 'org/qube'
  owner_id      TEXT NOT NULL REFERENCES users(id),
  description   TEXT,
  repository    TEXT,
  license       TEXT,
  latest        TEXT,                         -- latest non-yanked version
  created_at    TEXT NOT NULL
);

-- First-time name registrations awaiting admin approval.
-- Subsequent versions from an approved owner skip this queue.
CREATE TABLE pending_qubes (
  name           TEXT PRIMARY KEY,
  proposed_by    TEXT NOT NULL REFERENCES users(id),
  manifest       TEXT NOT NULL,               -- qube.json5 body
  archive_sha    TEXT NOT NULL,               -- SHA-256 hex; R2 key under pending/
  archive_size   INTEGER NOT NULL,
  submitted_at   TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'pending', -- 'pending' | 'rejected'
  reviewer_id    TEXT REFERENCES users(id),
  reviewed_at    TEXT,
  reject_reason  TEXT
);

CREATE INDEX idx_pending_status ON pending_qubes(status, submitted_at);

-- Published versions of approved qubes.
CREATE TABLE versions (
  qube_name      TEXT NOT NULL REFERENCES qubes(name),
  version        TEXT NOT NULL,
  manifest       TEXT NOT NULL,               -- qube.json5 body
  archive_sha    TEXT NOT NULL,               -- SHA-256 hex; R2 key under archives/
  archive_size   INTEGER NOT NULL,
  effects        TEXT NOT NULL,               -- JSON array of effect markers
  published_at   TEXT NOT NULL,
  yanked         INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (qube_name, version)
);

CREATE INDEX idx_versions_published ON versions(published_at);
