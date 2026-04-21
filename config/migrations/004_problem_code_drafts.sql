-- Stores one latest saved code draft per user/problem.
-- Idempotent: safe to re-run on existing databases.

CREATE TABLE IF NOT EXISTS app.problem_code_drafts (
    user_id     INT         NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    problem_id  INT         NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    language    VARCHAR(30) NOT NULL DEFAULT 'cpp',
    source_code TEXT        NOT NULL DEFAULT '',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, problem_id)
);

CREATE INDEX IF NOT EXISTS idx_problem_code_drafts_updated ON app.problem_code_drafts (updated_at DESC);
