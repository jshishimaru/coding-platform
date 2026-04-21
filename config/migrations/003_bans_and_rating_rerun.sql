-- Adds user ban state used by admin moderation and rating recalculation.
-- Idempotent: safe to re-run on existing databases.

ALTER TABLE app.users
    ADD COLUMN IF NOT EXISTS is_banned  BOOLEAN     NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS banned_at  TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS banned_by  INT REFERENCES app.users(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS ban_reason TEXT        NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_users_is_banned ON app.users (is_banned);
