-- Migration 002: Groups, group-based contests, proctoring,
-- subjective questions, custom grading, partial scoring, feedback.
--
-- Safe to run multiple times (all statements idempotent).
-- Apply to an existing DB with:
--     docker compose exec postgres psql -U postgres -d coding_platform -f /config/migrations/002_groups_grading_proctoring.sql

SET search_path TO app, public;

-- ── Groups ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS app.groups (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL UNIQUE,
    description TEXT         NOT NULL DEFAULT '',
    created_by  INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_groups_name ON app.groups (name);

CREATE TABLE IF NOT EXISTS app.group_members (
    group_id   INT         NOT NULL REFERENCES app.groups(id) ON DELETE CASCADE,
    user_id    INT         NOT NULL REFERENCES app.users(id)  ON DELETE CASCADE,
    role       VARCHAR(20) NOT NULL DEFAULT 'member',
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_group_members_user ON app.group_members (user_id);

CREATE TABLE IF NOT EXISTS app.group_join_requests (
    id          SERIAL PRIMARY KEY,
    group_id    INT          NOT NULL REFERENCES app.groups(id) ON DELETE CASCADE,
    user_id     INT          NOT NULL REFERENCES app.users(id)  ON DELETE CASCADE,
    status      VARCHAR(20)  NOT NULL DEFAULT 'pending',
    message     TEXT         NOT NULL DEFAULT '',
    decided_by  INT                   REFERENCES app.users(id)  ON DELETE SET NULL,
    decided_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gjr_group  ON app.group_join_requests (group_id);
CREATE INDEX IF NOT EXISTS idx_gjr_user   ON app.group_join_requests (user_id);
CREATE INDEX IF NOT EXISTS idx_gjr_status ON app.group_join_requests (status);

CREATE UNIQUE INDEX IF NOT EXISTS idx_gjr_one_pending
    ON app.group_join_requests (group_id, user_id)
    WHERE status = 'pending';

-- ── Contests: group / proctoring / grade visibility ────────
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS group_id         INT REFERENCES app.groups(id) ON DELETE SET NULL;
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS proctored        BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS grade_visibility VARCHAR(20) NOT NULL DEFAULT 'private';

CREATE INDEX IF NOT EXISTS idx_contests_group ON app.contests (group_id);

-- ── Problems: problem type ─────────────────────────────────
ALTER TABLE app.problems ADD COLUMN IF NOT EXISTS problem_type VARCHAR(20) NOT NULL DEFAULT 'standard';

-- ── Contest problems: partial scoring toggle ───────────────
ALTER TABLE app.contest_problems ADD COLUMN IF NOT EXISTS scoring_mode VARCHAR(20) NOT NULL DEFAULT 'all_or_nothing';

-- ── Submissions: manual grading / feedback / lock ──────────
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS manual_score INT;
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS feedback     TEXT        NOT NULL DEFAULT '';
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS graded_by    INT         REFERENCES app.users(id) ON DELETE SET NULL;
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS graded_at    TIMESTAMPTZ;
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS is_locked    BOOLEAN     NOT NULL DEFAULT FALSE;

-- ── Proctor events ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS app.proctor_events (
    id         SERIAL PRIMARY KEY,
    contest_id INT          NOT NULL REFERENCES app.contests(id) ON DELETE CASCADE,
    user_id    INT          NOT NULL REFERENCES app.users(id)    ON DELETE CASCADE,
    event_type VARCHAR(50)  NOT NULL,
    details    JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_proctor_events_contest_user ON app.proctor_events (contest_id, user_id);
CREATE INDEX IF NOT EXISTS idx_proctor_events_created      ON app.proctor_events (created_at DESC);
