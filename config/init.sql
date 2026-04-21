-- PostgreSQL Initialization Script for Coding Platform
-- This script runs when the container is first created

-- Create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Create database (if not exists)
SELECT 'CREATE DATABASE coding_platform'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'coding_platform')\gexec

-- Connect to the database
\c coding_platform

-- Create schema for application
CREATE SCHEMA IF NOT EXISTS app;

-- Set search path
ALTER DATABASE coding_platform SET search_path TO app, public;
SET search_path TO app, public;

-- Grant privileges
GRANT ALL PRIVILEGES ON SCHEMA app TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA app TO postgres;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA app TO postgres;

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION app.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

COMMENT ON FUNCTION app.update_updated_at_column() IS 'Automatically updates the updated_at column';

-- ============================================================
-- TABLES
-- ============================================================

-- 1. Users
CREATE TABLE IF NOT EXISTS app.users (
    id            SERIAL PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role          VARCHAR(20)  NOT NULL DEFAULT 'user',
    rating        INT          NOT NULL DEFAULT 1200,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_username ON app.users (username);
CREATE INDEX IF NOT EXISTS idx_users_email    ON app.users (email);

-- 2. Contests
CREATE TABLE IF NOT EXISTS app.contests (
    id          SERIAL PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    description TEXT         NOT NULL DEFAULT '',
    start_time  TIMESTAMPTZ  NOT NULL,
    end_time    TIMESTAMPTZ  NOT NULL,
    is_rated    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_by  INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_contests_start ON app.contests (start_time);
CREATE INDEX IF NOT EXISTS idx_contests_end   ON app.contests (end_time);

-- 3. Problems
CREATE TABLE IF NOT EXISTS app.problems (
    id              SERIAL PRIMARY KEY,
    title           VARCHAR(200) NOT NULL,
    slug            VARCHAR(200) NOT NULL UNIQUE,
    statement       TEXT         NOT NULL DEFAULT '',
    difficulty      VARCHAR(20)  NOT NULL DEFAULT 'medium',
    time_limit_ms   INT          NOT NULL DEFAULT 2000,
    memory_limit_mb INT          NOT NULL DEFAULT 256,
    checker_code    TEXT         NOT NULL DEFAULT '',
    created_by      INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    contest_id      INT                   REFERENCES app.contests(id) ON DELETE SET NULL,
    points          INT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_problems_slug       ON app.problems (slug);
CREATE INDEX IF NOT EXISTS idx_problems_difficulty  ON app.problems (difficulty);
CREATE INDEX IF NOT EXISTS idx_problems_contest     ON app.problems (contest_id);

-- 4. Submissions
CREATE TABLE IF NOT EXISTS app.submissions (
    id           SERIAL PRIMARY KEY,
    user_id      INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    problem_id   INT                   REFERENCES app.problems(id) ON DELETE SET NULL,
    contest_id   INT                   REFERENCES app.contests(id) ON DELETE SET NULL,
    language     VARCHAR(30)  NOT NULL,
    source_code  TEXT         NOT NULL,
    status       VARCHAR(30)  NOT NULL DEFAULT 'pending',
    runtime_ms   INT,
    memory_kb    INT,
    passed_count INT          DEFAULT 0,
    total_count  INT          DEFAULT 0,
    result_details JSONB,
    submitted_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_submissions_user    ON app.submissions (user_id);
CREATE INDEX IF NOT EXISTS idx_submissions_problem ON app.submissions (problem_id);
CREATE INDEX IF NOT EXISTS idx_submissions_contest ON app.submissions (contest_id);
CREATE INDEX IF NOT EXISTS idx_submissions_status  ON app.submissions (status);

-- 5. Test Cases
CREATE TABLE IF NOT EXISTS app.test_cases (
    id              SERIAL PRIMARY KEY,
    problem_id      INT     NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    input           TEXT    NOT NULL DEFAULT '',
    expected_output TEXT    NOT NULL DEFAULT '',
    is_sample       BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_test_cases_problem ON app.test_cases (problem_id);

-- 6. Contest Participants
CREATE TABLE IF NOT EXISTS app.contest_participants (
    id              SERIAL PRIMARY KEY,
    contest_id      INT NOT NULL REFERENCES app.contests(id) ON DELETE CASCADE,
    user_id         INT NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    score           INT NOT NULL DEFAULT 0,
    penalty_time    INT NOT NULL DEFAULT 0,
    rank            INT,
    rating_before   INT,
    rating_after    INT,
    rating_change   INT,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(contest_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_cp_contest ON app.contest_participants (contest_id);
CREATE INDEX IF NOT EXISTS idx_cp_user    ON app.contest_participants (user_id);
CREATE INDEX IF NOT EXISTS idx_cp_score   ON app.contest_participants (contest_id, score DESC, penalty_time ASC);

-- 7. Contest Problems (join table)
CREATE TABLE IF NOT EXISTS app.contest_problems (
    id              SERIAL PRIMARY KEY,
    contest_id      INT NOT NULL REFERENCES app.contests(id) ON DELETE CASCADE,
    problem_id      INT NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    points          INT NOT NULL DEFAULT 100,
    problem_order   INT NOT NULL DEFAULT 0,
    UNIQUE(contest_id, problem_id)
);

CREATE INDEX IF NOT EXISTS idx_cpb_contest ON app.contest_problems (contest_id);

-- 8. Contest Solves
CREATE TABLE IF NOT EXISTS app.contest_solves (
    id              SERIAL PRIMARY KEY,
    contest_id      INT NOT NULL REFERENCES app.contests(id) ON DELETE CASCADE,
    user_id         INT NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    problem_id      INT NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    submission_id   INT NOT NULL REFERENCES app.submissions(id) ON DELETE CASCADE,
    points_earned   INT NOT NULL DEFAULT 0,
    solved_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(contest_id, user_id, problem_id)
);

CREATE INDEX IF NOT EXISTS idx_cs_contest_user ON app.contest_solves (contest_id, user_id);

-- 9. Tags
CREATE TABLE IF NOT EXISTS app.tags (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE
);

-- 10. Problem-Tags (many-to-many join table)
CREATE TABLE IF NOT EXISTS app.problem_tags (
    problem_id INT NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    tag_id     INT NOT NULL REFERENCES app.tags(id)     ON DELETE CASCADE,
    PRIMARY KEY (problem_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_problem_tags_tag ON app.problem_tags (tag_id);

-- ============================================================
-- SEED DATA: Default tags
-- ============================================================
INSERT INTO app.tags (name) VALUES
    ('Array'), ('String'), ('Hash Table'), ('Dynamic Programming'), ('Math'),
    ('Sorting'), ('Greedy'), ('Binary Search'), ('Tree'), ('Graph'),
    ('Linked List'), ('Two Pointers'), ('Sliding Window'), ('Stack'), ('Queue'),
    ('Recursion'), ('Backtracking'), ('Bit Manipulation'), ('Heap'), ('Trie')
ON CONFLICT (name) DO NOTHING;


-- ============================================================
-- ADMIN PORTAL TABLES
-- ============================================================

-- Add permissions column to users (fine-grained RBAC overrides)
ALTER TABLE app.users ADD COLUMN IF NOT EXISTS permissions JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Extend contests with scoring configuration and lifecycle state
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS scoring_type          VARCHAR(20) NOT NULL DEFAULT 'icpc';
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS freeze_time_minutes   INT;
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS status                VARCHAR(20) NOT NULL DEFAULT 'draft';
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS penalty_time_seconds  INT NOT NULL DEFAULT 1200;
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS allow_virtual         BOOLEAN NOT NULL DEFAULT FALSE;

-- Extend contest_problems with IOI scoring support
ALTER TABLE app.contest_problems ADD COLUMN IF NOT EXISTS max_points      INT NOT NULL DEFAULT 100;
ALTER TABLE app.contest_problems ADD COLUMN IF NOT EXISTS scoring_config  JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Extend test_cases with provenance tracking
ALTER TABLE app.test_cases ADD COLUMN IF NOT EXISTS generator_batch_id INT;
ALTER TABLE app.test_cases ADD COLUMN IF NOT EXISTS order_index        INT NOT NULL DEFAULT 0;
ALTER TABLE app.test_cases ADD COLUMN IF NOT EXISTS created_by         INT;
ALTER TABLE app.test_cases ADD COLUMN IF NOT EXISTS created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- 11. Problem Revisions — simple revision tracking
CREATE TABLE IF NOT EXISTS app.problem_revisions (
    id              SERIAL PRIMARY KEY,
    problem_id      INT          NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    revision        INT          NOT NULL,
    title           VARCHAR(200) NOT NULL,
    statement       TEXT         NOT NULL DEFAULT '',
    difficulty      VARCHAR(20)  NOT NULL DEFAULT 'medium',
    time_limit_ms   INT          NOT NULL DEFAULT 2000,
    memory_limit_mb INT          NOT NULL DEFAULT 256,
    checker_code    TEXT         NOT NULL DEFAULT '',
    points          INT,
    is_active       BOOLEAN      NOT NULL DEFAULT FALSE,
    created_by      INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE(problem_id, revision)
);

CREATE INDEX IF NOT EXISTS idx_problem_revisions_problem ON app.problem_revisions (problem_id);

-- 12. Problem Generators — C++ test generators (testlib.h)
--
-- Like validators/checkers/interactors, at most one generator per problem is
-- "active" at a time. The generate-tests endpoint uses the active generator
-- unless the caller explicitly passes a generator_id.
CREATE TABLE IF NOT EXISTS app.problem_generators (
    id          SERIAL PRIMARY KEY,
    problem_id  INT          NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    name        VARCHAR(100) NOT NULL,
    source_code TEXT         NOT NULL DEFAULT '',
    description TEXT         NOT NULL DEFAULT '',
    is_active   BOOLEAN      NOT NULL DEFAULT FALSE,
    created_by  INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_problem_generators_problem ON app.problem_generators (problem_id);

-- 13. Problem Validators — input validators
CREATE TABLE IF NOT EXISTS app.problem_validators (
    id          SERIAL PRIMARY KEY,
    problem_id  INT          NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    name        VARCHAR(100) NOT NULL,
    source_code TEXT         NOT NULL DEFAULT '',
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_by  INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_problem_validators_problem ON app.problem_validators (problem_id);

-- 14. Problem Checkers — custom checkers (standard, partial, interactive)
CREATE TABLE IF NOT EXISTS app.problem_checkers (
    id           SERIAL PRIMARY KEY,
    problem_id   INT          NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    name         VARCHAR(100) NOT NULL,
    source_code  TEXT         NOT NULL DEFAULT '',
    checker_type VARCHAR(20)  NOT NULL DEFAULT 'standard',
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_by   INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_problem_checkers_problem ON app.problem_checkers (problem_id);

-- 15. Problem Interactors — interactive problem communication programs
CREATE TABLE IF NOT EXISTS app.problem_interactors (
    id          SERIAL PRIMARY KEY,
    problem_id  INT          NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    name        VARCHAR(100) NOT NULL,
    source_code TEXT         NOT NULL DEFAULT '',
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_by  INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_problem_interactors_problem ON app.problem_interactors (problem_id);

-- 16. Problem Solutions — model/reference solutions
CREATE TABLE IF NOT EXISTS app.problem_solutions (
    id               SERIAL PRIMARY KEY,
    problem_id       INT          NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    name             VARCHAR(100) NOT NULL,
    source_code      TEXT         NOT NULL DEFAULT '',
    expected_verdict VARCHAR(30)  NOT NULL DEFAULT 'AC',
    tag              VARCHAR(30)  NOT NULL DEFAULT 'main',
    created_by       INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_problem_solutions_problem ON app.problem_solutions (problem_id);

-- 17. Generated Test Batches — track test generation runs
CREATE TABLE IF NOT EXISTS app.generated_test_batches (
    id            SERIAL PRIMARY KEY,
    problem_id    INT         NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    generator_id  INT         NOT NULL REFERENCES app.problem_generators(id) ON DELETE CASCADE,
    args          TEXT        NOT NULL DEFAULT '',
    test_count    INT         NOT NULL DEFAULT 0,
    validated     BOOLEAN     NOT NULL DEFAULT FALSE,
    created_by    INT         NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gen_batches_problem ON app.generated_test_batches (problem_id);

-- Add FK from test_cases to generated_test_batches (after table creation)
ALTER TABLE app.test_cases ADD CONSTRAINT fk_test_cases_batch
    FOREIGN KEY (generator_batch_id)
    REFERENCES app.generated_test_batches(id) ON DELETE SET NULL;

-- 18. Problem Access — per-problem RBAC
CREATE TABLE IF NOT EXISTS app.problem_access (
    id          SERIAL PRIMARY KEY,
    problem_id  INT         NOT NULL REFERENCES app.problems(id) ON DELETE CASCADE,
    user_id     INT         NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    role        VARCHAR(20) NOT NULL DEFAULT 'viewer',
    granted_by  INT         NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(problem_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_problem_access_problem ON app.problem_access (problem_id);
CREATE INDEX IF NOT EXISTS idx_problem_access_user    ON app.problem_access (user_id);

-- 19. Admin Audit Log — action audit trail
CREATE TABLE IF NOT EXISTS app.admin_audit_log (
    id          SERIAL PRIMARY KEY,
    user_id     INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    action      VARCHAR(100) NOT NULL,
    entity_type VARCHAR(50)  NOT NULL,
    entity_id   INT          NOT NULL,
    details     JSONB        NOT NULL DEFAULT '{}'::jsonb,
    ip_address  VARCHAR(45)  NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_user      ON app.admin_audit_log (user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_action    ON app.admin_audit_log (action);
CREATE INDEX IF NOT EXISTS idx_audit_log_entity    ON app.admin_audit_log (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_created   ON app.admin_audit_log (created_at DESC);


-- ============================================================
-- GROUPS / GROUP CONTESTS / PROCTORING / SUBJECTIVE / GRADING
-- ============================================================

-- 20. Groups
CREATE TABLE IF NOT EXISTS app.groups (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL UNIQUE,
    description TEXT         NOT NULL DEFAULT '',
    created_by  INT          NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_groups_name ON app.groups (name);

-- 21. Group Members (role is 'member' or 'admin' within the group)
CREATE TABLE IF NOT EXISTS app.group_members (
    group_id   INT         NOT NULL REFERENCES app.groups(id) ON DELETE CASCADE,
    user_id    INT         NOT NULL REFERENCES app.users(id)  ON DELETE CASCADE,
    role       VARCHAR(20) NOT NULL DEFAULT 'member',
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_group_members_user ON app.group_members (user_id);

-- 22. Group Join Requests
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

-- Only one pending request per (group, user)
CREATE UNIQUE INDEX IF NOT EXISTS idx_gjr_one_pending
    ON app.group_join_requests (group_id, user_id)
    WHERE status = 'pending';

-- 23. Contests: group association + proctoring + grade visibility
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS group_id           INT REFERENCES app.groups(id) ON DELETE SET NULL;
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS proctored          BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE app.contests ADD COLUMN IF NOT EXISTS grade_visibility   VARCHAR(20) NOT NULL DEFAULT 'private';

CREATE INDEX IF NOT EXISTS idx_contests_group ON app.contests (group_id);

-- 24. Problems: problem type (standard vs subjective)
ALTER TABLE app.problems ADD COLUMN IF NOT EXISTS problem_type VARCHAR(20) NOT NULL DEFAULT 'standard';

-- 24b. Problems: publish state (NULL = draft, not visible to students)
ALTER TABLE app.problems ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_problems_published_at ON app.problems (published_at);

-- 25. Contest problems: per-problem scoring mode (all_or_nothing vs partial)
ALTER TABLE app.contest_problems ADD COLUMN IF NOT EXISTS scoring_mode VARCHAR(20) NOT NULL DEFAULT 'all_or_nothing';

-- 26. Submissions: manual grading / feedback / lock
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS manual_score INT;
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS feedback     TEXT        NOT NULL DEFAULT '';
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS graded_by    INT         REFERENCES app.users(id) ON DELETE SET NULL;
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS graded_at    TIMESTAMPTZ;
ALTER TABLE app.submissions ADD COLUMN IF NOT EXISTS is_locked    BOOLEAN     NOT NULL DEFAULT FALSE;

-- 27. Proctor events — monitoring log
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
