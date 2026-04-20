# Project Context: Coding Platform

This document captures the current technical context of the `coding-platform` workspace, including architecture, implemented features, API and UI surface, data model updates, scripts, and known operational notes.

## 1) What this project is

A full-stack coding platform (LeetCode/Codeforces style) with:
- public problem solving
- contest participation (ICPC/IOI style)
- admin authoring and grading workflows
- secure C++ execution sandbox
- ratings and contest history

In this workspace, the system is split into:
- `src/backend` (Go + Gin API)
- `src/frontend` (student-facing React app)
- `src/admin-frontend` (admin React app)
- root Docker orchestration (`docker-compose.yml`)
- DB init/migrations (`config/init.sql`, `config/migrations/*.sql`)
- helper scripts (`scripts/*.sh`)

## 2) Runtime architecture

### Services
Defined in `docker-compose.yml`:
- `postgres` (PostgreSQL 15, host port `5433`)
- `redis` (Redis 7, host port `6380`)
- `backend` (Go API, host port `3000`)
- `frontend` (student UI, host port `8080`)
- `admin-frontend` (admin UI, host port `8081`)

### Typical local URLs
- Student UI: `http://localhost:8080`
- Admin UI: `http://localhost:8081`
- API health: `http://localhost:3000/api/health`

## 3) Core stacks and conventions

### Backend
- Go 1.22
- Gin
- pgx + PostgreSQL
- Redis
- JWT auth middleware (`AuthRequired`, `AuthOptional`)
- SSE endpoints for ratings stream

### Frontend/Admin frontend
- React 18 + TypeScript + Vite
- Tailwind CSS
- React Query (`@tanstack/react-query`)
- Monaco editor for code view/edit

### Access control model
- Site roles: `user`, `tester`, `setter`, `admin`
- Group roles: `member`, `admin`
- Site admins can create/delete groups and create group contests
- Group admins manage members and join requests

## 4) Major feature set implemented

### A) Groups system
Implemented across backend, student frontend, and admin frontend.

Capabilities:
- Admin creates groups
- Users browse/search groups
- Users request to join
- Group admin (or site admin) approves/rejects requests
- Users can leave groups
- Group admins manage members and roles

Key behavior:
- Users can belong to multiple groups
- Group metadata includes member counts and current user membership role

### B) Group-based contests
Contests can be associated with a `group_id`.

Behavior:
- Group contests are visible only to group members
- Non-members cannot access group contest detail
- Group contests are treated as unrated by default when created through admin flow
- Group contests can have their own leaderboard/results scope

### C) Proctored mode
Per contest toggle: `proctored`.

Student client behavior:
- Captures and logs proctoring events to backend endpoint
- Includes fullscreen controls and warning banner

Logged events include:
- fullscreen enter/exit
- tab visibility changes
- window blur/focus
- right-click
- devtools suspicion heuristic
- copy/paste
- unload/session start

Admin behavior:
- Contest-level event list
- Contest-level summary by user/event counts

### D) Subjective problem type
Problem type supports:
- `standard` (auto judged)
- `subjective` (manual review)

Behavior for subjective:
- submission accepted for review (no normal testcase result UX)
- student UI shows “awaiting manual review”
- admin can score/feedback/lock submission

### E) Custom grading + feedback
Admin submission tools:
- view all submissions with filters
- inspect source code
- run code in sandbox
- apply manual score
- provide feedback text
- lock/finalize grading state

Student tools:
- view own submission history
- view per-submission details
- see manual score + instructor feedback

### F) Grade visibility control
Contest-level setting:
- `private`: student sees own score
- `group`: group-level visibility for group participants

### G) Partial scoring
Contest problem has `scoring_mode`:
- `all_or_nothing`
- `partial`

Used in contest problem configuration for assignment-like and regular contests.

### H) Export grades
Admin endpoint and UI support CSV export per contest including rank/score/participant rows and per-problem columns.

## 5) Important API route surface (high level)

### Public / authenticated student routes
- `/api/auth/*`
- `/api/questions`, `/api/questions/:slug`, `/api/questions/:slug/run`
- `/api/contests` and `/api/contests/:id` (optional auth for visibility filtering)
- `/api/contests/:id/submit`
- `/api/contests/:id/proctor-events`
- `/api/submissions/mine`, `/api/submissions/:id`
- `/api/groups`, `/api/groups/:id`, join/cancel/leave

### Admin routes
- `/api/admin/contests/*` (create/edit/problems/publish/finalize)
- `/api/admin/contests/:id/proctor-events`
- `/api/admin/contests/:id/proctor-summary`
- `/api/admin/contests/:id/export.csv`
- `/api/admin/submissions`, `/api/admin/submissions/:id`, grading/run endpoints
- `/api/admin/groups/*` (create/update/delete, requests, members)
- `/api/admin/problems/*` (authoring/revisions/tests/access/components)

## 6) Database context

### Base schema
- `config/init.sql` contains full bootstrap schema
- includes legacy/core tables + newer groups/proctoring/grading additions

### Incremental migration
- `config/migrations/002_groups_grading_proctoring.sql`
- idempotent migration adding:
  - `groups`
  - `group_members`
  - `group_join_requests`
  - contest columns: `group_id`, `proctored`, `grade_visibility`
  - problem column: `problem_type`
  - contest problem column: `scoring_mode`
  - submission columns: `manual_score`, `feedback`, `graded_by`, `graded_at`, `is_locked`
  - `proctor_events`

## 7) Frontend areas added/updated

### Student frontend (`src/frontend`)
- Groups pages:
  - `features/groups/pages/GroupListPage.tsx`
  - `features/groups/pages/GroupDetailPage.tsx`
- Submissions pages:
  - `features/submissions/pages/MySubmissionsPage.tsx`
  - `features/submissions/pages/SubmissionDetailPage.tsx`
  - `features/submissions/components/SubmissionStatusBadge.tsx`
- Proctoring:
  - `features/proctoring/useProctoring.ts`
  - `features/proctoring/ProctoringBanner.tsx`
- Contest/question rendering updates for:
  - group/proctored/grade-visibility badges
  - subjective submission UX
- Router and main nav include Groups and Submissions entries.

### Admin frontend (`src/admin-frontend`)
- Groups pages:
  - list/create/detail pages
- Submissions pages:
  - list/detail with grading tools
- Contest editor/create:
  - group, proctored, grade visibility, scoring mode, proctor panel, export CSV trigger
- Problem editor:
  - problem type support in create/edit flow
- Admin nav and router include Groups and Submissions sections.

## 8) Scripts and operational workflow

### Primary scripts
- `scripts/setup.sh` — clones backend/frontend repos into `src/` (if needed)
- `scripts/build.sh` — builds images
- `scripts/run.sh` — runs stack and basic health checks
- `scripts/seed.sh` — seeds users/problems/contests and extended demo data
- `scripts/migrate.sh` — applies `config/migrations/*.sql` to existing DB

### `seed.sh` (current extended behavior)
In addition to base seed data, it now seeds:
- one subjective problem (`essay-binary-search`)
- one demo group (`CS101 Spring 2026`)
- group members/admin assignments
- one pending join request
- one group-only, proctored contest with mixed scoring modes

Notes:
- Seed flow is mostly idempotent for newly added group/subjective/group-contest data.
- Repeated runs may still create duplicate legacy global contests if those sections are not deduped by title checks.

## 9) Validation/smoke test state (last verified)

End-to-end checks were run after rebuild and migration:
- backend, frontend, admin frontend containers started successfully
- migration `002_groups_grading_proctoring.sql` applied successfully
- seed script completed and created group + subjective problem + group contest
- group contest visibility works (member sees it, non-member is blocked)
- proctor event ingestion works and appears in admin list/summary
- admin submissions list and contest CSV export endpoints return valid responses

## 10) Known caveats / current repo state

- Working tree is not clean; there are ongoing changes across root and nested project directories.
- `init.sql` is only executed on first DB initialization (empty Postgres volume).
  - Use `scripts/migrate.sh` for existing databases.
- Admin and student frontends rely on backend response shapes that were recently aligned; keep type definitions synchronized with backend contracts during future changes.

## 11) Suggested developer quick start (from current state)

1. Start services:
   - `./scripts/run.sh`
2. For existing DBs, apply migrations:
   - `./scripts/migrate.sh`
3. Seed data:
   - `./scripts/seed.sh`
4. Access apps:
   - student: `http://localhost:8080`
   - admin: `http://localhost:8081`

Default seeded credentials:
- `admin / password123` (site admin)
- `alice`, `bob`, `charlie`, `diana`, `eve` with same password

---

If this file gets stale, refresh it by re-checking:
- `docker-compose.yml`
- `config/init.sql`
- `config/migrations/*.sql`
- `src/backend/internal/router/router.go`
- `scripts/seed.sh`
- `scripts/migrate.sh`
- frontend/admin router + feature modules
