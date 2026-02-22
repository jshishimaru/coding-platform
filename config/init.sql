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
