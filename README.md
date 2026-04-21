# Coding Platform

A full-stack coding platform (similar to LeetCode or Codeforces) featuring a Go/Gin backend, React/Vite frontend, PostgreSQL database, Redis caching, and a secure C++ code execution sandbox. It supports user authentication, problem solving, real-time contest participation, leaderboards, and an ELO rating system.

## Features

- **User Authentication:** Secure JWT-based login and registration.
- **Problem Solving:** Browse, filter, and solve coding problems with a side-by-side code editor.
- **Code Execution Sandbox:** Securely compile and run C++ code in an isolated Docker environment with resource limits (time and memory).
- **Contests:** Participate in live coding contests with real-time leaderboards and an ELO rating predictor.
- **Real-time Updates:** Server-Sent Events (SSE) for live rating predictions during contests.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)
- Git

## Setup Instructions

The project is structured to run entirely within Docker. The frontend and backend codebases are hosted in separate repositories and need to be cloned into the `src/` directory.

### 1. Clone the Main Repository

```bash
git clone <this-repository-url> coding-platform
cd coding-platform
```

### 2. Setup Frontend and Backend

Run the setup script to automatically clone the frontend and backend repositories into the `src/` directory:

```bash
./scripts/setup.sh
```

This script will clone:
- Frontend: `https://github.com/jshishimaru/coding-platform-frontend.git` into `src/frontend`
- Backend: `https://github.com/jshishimaru/coding-platform-backend.git` into `src/backend`

### 3. Build the Docker Images

Build the Docker images for all services (PostgreSQL, Redis, Backend, Frontend):

```bash
./scripts/build.sh
```

### 4. Run the Application

Start all services using Docker Compose:

```bash
./scripts/run.sh
```

This script will start the containers and check their health. Once running, you can access the platform at:

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

## Architecture

- **Frontend:** React 18, TypeScript, Vite, Tailwind CSS, Monaco Editor. Served via Nginx.
- **Backend:** Go 1.22, Gin Web Framework, JWT Authentication.
- **Database:** PostgreSQL 15 (Port 5433 on host).
- **Cache:** Redis 7 (Port 6380 on host).
- **Sandbox:** Custom Alpine-based Docker image with `g++` for secure code execution.

## Useful Commands

- **View all running containers:**
  ```bash
  docker ps
  ```
- **View logs for all services:**
  ```bash
  docker compose logs -f
  ```
- **Stop all services:**
  ```bash
  docker compose down
  ```
- **Restart services:**
  ```bash
  ./scripts/run.sh
  ```
