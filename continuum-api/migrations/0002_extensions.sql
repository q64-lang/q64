-- 0002: approval lifecycle, scanning, provenance, audit, FTS5 search.

-- Approval lifecycle on users.
ALTER TABLE users ADD COLUMN status TEXT NOT NULL DEFAULT 'unverified';
-- 'unverified' | 'pending_review' | 'approved' | 'suspended'
ALTER TABLE users ADD COLUMN approved_at TEXT;
ALTER TABLE users ADD COLUMN approved_by TEXT;
ALTER TABLE users ADD COLUMN second_factor_kind TEXT;
-- 'second_oauth' | 'passkey' | 'github_binding' | null
CREATE INDEX idx_users_status ON users(status);

-- Per-version async scanning (backstop).
ALTER TABLE versions ADD COLUMN scan_status TEXT NOT NULL DEFAULT 'pending';
-- 'pending' | 'clean' | 'flagged' | 'blocked'
ALTER TABLE versions ADD COLUMN scan_result TEXT;
CREATE INDEX idx_versions_scan ON versions(scan_status);

-- TrustPub-style CI provenance per version.
ALTER TABLE versions ADD COLUMN published_via TEXT;
-- 'github_actions' | 'manual' | null
ALTER TABLE versions ADD COLUMN provenance TEXT;
-- JSON: { repo, run_id, sha, workflow_path }

-- Download counters on qubes.
ALTER TABLE qubes ADD COLUMN downloads INTEGER NOT NULL DEFAULT 0;
ALTER TABLE qubes ADD COLUMN recent_downloads INTEGER NOT NULL DEFAULT 0;

-- Denormalized fields for FTS5 (space-joined at publish time).
ALTER TABLE qubes ADD COLUMN keywords TEXT NOT NULL DEFAULT '';
ALTER TABLE qubes ADD COLUMN categories TEXT NOT NULL DEFAULT '';

-- Audit log for admin actions.
CREATE TABLE audit_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  actor_id      TEXT NOT NULL REFERENCES users(id),
  action        TEXT NOT NULL,
  -- approve_user | reject_user | yank_version | unyank_version | suspend_user | unsuspend_user
  target_kind   TEXT NOT NULL,        -- 'user' | 'qube' | 'version'
  target_id     TEXT NOT NULL,
  reason        TEXT,
  metadata      TEXT,                  -- JSON, action-specific
  created_at    TEXT NOT NULL
);
CREATE INDEX idx_audit_actor ON audit_log(actor_id, created_at);
CREATE INDEX idx_audit_target ON audit_log(target_kind, target_id);

-- FTS5 virtual table for search (BM25 ranking).
CREATE VIRTUAL TABLE qubes_fts USING fts5(
  name,
  description,
  keywords,
  categories,
  content='qubes',
  content_rowid='rowid',
  tokenize='unicode61'
);

-- Keep FTS in sync via triggers.
CREATE TRIGGER qubes_fts_ai AFTER INSERT ON qubes BEGIN
  INSERT INTO qubes_fts(rowid, name, description, keywords, categories)
  VALUES (new.rowid, new.name, new.description, new.keywords, new.categories);
END;

CREATE TRIGGER qubes_fts_ad AFTER DELETE ON qubes BEGIN
  INSERT INTO qubes_fts(qubes_fts, rowid, name, description, keywords, categories)
  VALUES ('delete', old.rowid, old.name, old.description, old.keywords, old.categories);
END;

CREATE TRIGGER qubes_fts_au AFTER UPDATE ON qubes BEGIN
  INSERT INTO qubes_fts(qubes_fts, rowid, name, description, keywords, categories)
  VALUES ('delete', old.rowid, old.name, old.description, old.keywords, old.categories);
  INSERT INTO qubes_fts(rowid, name, description, keywords, categories)
  VALUES (new.rowid, new.name, new.description, new.keywords, new.categories);
END;
