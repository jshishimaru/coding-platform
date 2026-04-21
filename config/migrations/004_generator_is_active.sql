-- 004_generator_is_active.sql
-- Promote generators to the same "exactly-one-active" model as validators,
-- checkers, and interactors.
--
-- Design:
--   app.problem_generators.is_active BOOLEAN NOT NULL DEFAULT FALSE
--     FALSE -> generator exists but will not be used implicitly; callers must
--              pass its id explicitly to /tests/generate
--     TRUE  -> picked up automatically when the admin UI presses "Generate"
--              without selecting a generator. At most one row per problem
--              should be TRUE; the activate endpoint enforces this in a txn.
--
-- Policy for existing rows: if a problem has exactly one generator we mark it
-- active automatically (no one is going to miss a surprise). Otherwise we
-- leave them all inactive and let the admin pick explicitly.

BEGIN;

ALTER TABLE app.problem_generators
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT FALSE;

-- Auto-activate the sole generator for problems that have exactly one.
WITH solo AS (
    SELECT problem_id
      FROM app.problem_generators
     GROUP BY problem_id
    HAVING COUNT(*) = 1
)
UPDATE app.problem_generators g
   SET is_active = TRUE
  FROM solo
 WHERE g.problem_id = solo.problem_id
   AND g.is_active  = FALSE;

COMMIT;
