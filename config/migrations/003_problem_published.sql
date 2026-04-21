-- 003_problem_published.sql
-- Introduce a first-class publish flag on problems.
--
-- Design:
--   app.problems.published_at TIMESTAMPTZ NULL
--     NULL  -> problem is a draft; hidden from student-facing endpoints
--     set   -> problem is published; visible to everyone who otherwise has access
--
-- Policy for existing rows: DRAFT.
-- Rationale: the instructor explicitly asked for existing problems to become
-- drafts so nothing is leaked without a deliberate publish action. If you want
-- to keep the historical "all visible" behaviour on a specific environment,
-- run the commented-out UPDATE at the bottom of this file once, manually.

BEGIN;

ALTER TABLE app.problems
    ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_problems_published_at
    ON app.problems (published_at);

-- Explicitly leave every existing problem as a draft. This is a no-op because
-- the column defaults to NULL, but the statement documents intent and is safe
-- to re-run because it only touches rows that are already drafts.
UPDATE app.problems
   SET published_at = NULL
 WHERE published_at IS NULL;

COMMIT;

-- Opt-in: re-publish everything (run manually only if you want the old
-- behaviour where every existing problem stays visible after the migration):
--
-- UPDATE app.problems SET published_at = NOW() WHERE published_at IS NULL;
