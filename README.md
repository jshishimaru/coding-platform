# Coding Platform

A full-stack coding platform similar to LeetCode or Codeforces. The stack includes a Go/Gin backend API, a student-facing React/Vite frontend, an admin React/Vite frontend, PostgreSQL, Redis, and a secure C++ execution sandbox.

## Features

- **User Authentication:** JWT-based login, registration, logout, and role-aware access.
- **Problem Solving:** Browse, filter, and solve coding problems with a code editor and sample tests.
- **Contests:** Run public, private, group-based, rated, unrated, ICPC-style, and IOI-style contests.
- **Admin Portal:** Manage problems, contests, test cases, groups, users, submissions, grading, proctoring, and exports.
- **Code Execution Sandbox:** Compile and run C++ code in an isolated Docker-based sandbox with time and memory limits.
- **Manual Grading:** Support subjective problems, instructor feedback, manual scores, and locked grades.
- **Proctoring:** Record contest proctoring events and review summaries from the admin portal.

## Prerequisites

- Docker
- Docker Compose
- Git
- Bash-compatible shell

## Repository Layout

```text
.
├── config/
│   ├── init.sql              # Current bootstrap schema for fresh databases
│   ├── migrations/           # Optional upgrade migrations for existing databases
│   ├── postgres.conf
│   └── redis.conf
├── scripts/
│   ├── setup.sh              # Fetches split frontend/backend repos when needed
│   ├── build.sh              # Builds Docker images
│   ├── run.sh                # Starts the full stack
│   ├── migrate.sh            # Applies config/migrations/*.sql
│   └── seed.sh               # Seeds demo users, problems, contests, groups
├── src/
│   ├── backend/              # Go API
│   ├── frontend/             # Student frontend
│   └── admin-frontend/       # Admin frontend
├── postgres/                 # Local Postgres bind-mounted data
├── redis/                    # Local Redis bind-mounted data
└── docker-compose.yml
```

## Services And Ports

The default Docker Compose stack starts:

| Service | Container | Host URL / Port |
| --- | --- | --- |
| Student frontend | `coding-platform-app` | `http://localhost:8080` |
| Admin frontend | `coding-platform-admin` | `http://localhost:8081` |
| Backend API | `coding-platform-backend` | `http://localhost:3000/api/health` |
| PostgreSQL | `coding-platform-postgres` | `localhost:5433` |
| Redis | `coding-platform-redis` | `localhost:6380` |

The port defaults are set in `docker-compose.yml` and repeated by `scripts/run.sh`.

## First-Time Setup

1. Clone this repository:

   ```bash
   git clone <this-repository-url> coding-platform
   cd coding-platform
   ```

2. Ensure the application source directories exist under `src/`:

   ```text
   src/backend
   src/frontend
   src/admin-frontend
   ```

   In this workspace, all three are already present. If you are using the split-repository setup, run:

   ```bash
   ./scripts/setup.sh
   ```

   `scripts/setup.sh` prepares the backend and student frontend repositories. The admin frontend must also be present at `src/admin-frontend` before building the full Docker stack.

3. Build all service images:

   ```bash
   ./scripts/build.sh
   ```

4. Start the full stack:

   ```bash
   ./scripts/run.sh
   ```

5. Seed demo data:

   ```bash
   ./scripts/seed.sh
   ```

6. Open the apps:

   - Student frontend: `http://localhost:8080`
   - Admin frontend: `http://localhost:8081`
   - Backend health: `http://localhost:3000/api/health`

After seeding, the demo admin account is:

```text
username: admin
password: password123
```

All seeded users use `password123`.

## Database Schema

`config/init.sql` is the source of truth for a fresh local database. PostgreSQL runs this file only when its data directory is empty.

The local database is stored in:

```text
postgres/pgdata
```

Because the project uses a bind mount, `docker compose down` stops containers but does not delete the database files.

## Applying Migrations

Use migrations when you already have a database and want to apply incremental schema changes without deleting data.

1. Start the stack:

   ```bash
   ./scripts/run.sh
   ```

2. Apply every SQL migration in `config/migrations/`, in filename order:

   ```bash
   ./scripts/migrate.sh
   ```

The migration script is safe when there are no migration files; it will print that there is nothing to do.

Important: `init.sql` is not rerun for an existing database. If you changed only `init.sql`, you must recreate the database or write a migration that applies the same change to existing databases.

## Removing And Recreating The Database

For local testing, you can completely reset Postgres and rebuild it from `config/init.sql`.

This deletes all local database data:

```bash
docker compose down
rm -rf postgres/pgdata
./scripts/run.sh
./scripts/seed.sh
```

If file permissions prevent deletion, run:

```bash
sudo rm -rf postgres/pgdata
```

Redis data can also be reset if needed:

```bash
docker compose down
rm -rf postgres/pgdata redis/*
./scripts/run.sh
./scripts/seed.sh
```

Keep `postgres/.gitkeep` and `redis/.gitkeep` if you want the placeholder files to remain in Git.

## Useful Commands

View running containers:

```bash
docker ps
```

View all logs:

```bash
docker compose logs -f
```

View one service log:

```bash
docker compose logs -f backend
docker compose logs -f postgres
docker compose logs -f admin-frontend
```

Stop all services:

```bash
docker compose down
```

Restart and rebuild services:

```bash
./scripts/run.sh
```

Run migrations:

```bash
./scripts/migrate.sh
```
- **Frontend:** [http://localhost:8080](http://localhost:8080)
- **Admin frontend:** [http://localhost:8081](http://localhost:8081)
- **Backend API:** [http://localhost:3000/api/health](http://localhost:3000/api/health)
- **Database admin (Adminer):** [http://localhost:8082](http://localhost:8082)

## Database admin (Adminer)

A lightweight [Adminer](https://www.adminer.org/) instance runs alongside the app and gives you a Django-admin-style UI over every table in the `app` schema, with full CRUD (list, filter, sort, insert, edit, delete, bulk actions, SQL console). Because it introspects `information_schema` live, it picks up new tables/columns automatically whenever [`config/init.sql`](config/init.sql) or a future migration runs — no redeploy needed.

- URL: [http://localhost:8082](http://localhost:8082)
- System: **PostgreSQL**
- Server: `coding-platform-postgres` (pre-filled)
- Username / Password: from your `.env` (defaults: `postgres` / `postgres`)
- Database: `coding_platform`
- Schema: `app`

**Usage caveat:** Adminer writes directly to the live database. There is no app-level guardrail — no `admin_audit_log` entry, no soft-delete, no role-aware hiding. Use Adminer for read, debugging, and small fixes; prefer the admin frontend for routine operations, since that path writes to the audit log.

Seed demo data:

```bash
./scripts/seed.sh
```

Connect to Postgres:

```bash
docker compose exec postgres psql -U postgres -d coding_platform
```

## Development Notes

- The backend connects to Postgres and Redis through Docker service names inside the Compose network.
- The student and admin frontends are served by Nginx containers.
- The admin frontend expects admin JWTs in browser local storage under `admin_token`.
- `config/init.sql` should contain the complete current schema for new local databases.
- `config/migrations/*.sql` should be idempotent and used only for upgrading already-existing databases.
