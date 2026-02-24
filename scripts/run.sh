#!/bin/bash

# Script to run all containers for the coding platform
# Starts: postgres, redis, backend microservices, api gateway, frontend

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🚀 Starting Coding Platform Services"
echo "================================================"
echo ""

cd "$PROJECT_ROOT"

# Set explicit port mappings to avoid conflicts with host services
export POSTGRES_PORT=5433
export REDIS_PORT=6380
export BACKEND_PORT=3000
export FRONTEND_PORT=8080
export ADMIN_PORT=8081

# Fix permissions on data directories
echo "🔧 Fixing data directory permissions..."
sudo chown -R $(id -u):$(id -g) ./postgres ./redis 2>/dev/null || true

# Stop any existing containers
echo "🧹 Cleaning up existing containers..."
docker compose down 2>/dev/null || true
sleep 1

# Build and start all services
echo "📦 Starting all services..."
docker compose up -d --build

# Wait for services to come up
echo "⏳ Waiting for services to be ready..."
sleep 5

echo ""
echo "🔍 Checking service health..."

# Check postgres
echo -n "  PostgreSQL: "
docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1 && echo "✅ connected" || echo "⚠️  starting up"

# Check redis
echo -n "  Redis: "
docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG && echo "✅ connected" || echo "⚠️  starting up"

# Check backend
echo -n "  Backend: "
container_status=$(docker inspect --format='{{.State.Status}}' coding-platform-backend 2>/dev/null || echo "not found")
if [ "$container_status" = "running" ]; then
    echo "✅ running"
else
    echo "⚠️  $container_status"
fi

# Check frontend
echo -n "  Frontend: "
container_status=$(docker inspect --format='{{.State.Status}}' coding-platform-app 2>/dev/null || echo "not found")
if [ "$container_status" = "running" ]; then
    echo "✅ running"
else
    echo "⚠️  $container_status"
fi

# Check admin frontend
echo -n "  Admin Frontend: "
container_status=$(docker inspect --format='{{.State.Status}}' coding-platform-admin 2>/dev/null || echo "not found")
if [ "$container_status" = "running" ]; then
    echo "✅ running"
else
    echo "⚠️  $container_status"
fi

echo ""
echo "================================================"
echo "✅ Services Started!"
echo ""
echo "📊 Access Points:"
echo "  - Frontend:     http://localhost:$FRONTEND_PORT"
echo "  - Admin Portal:  http://localhost:$ADMIN_PORT"
echo "  - Backend API:  http://localhost:$BACKEND_PORT/api/health"
echo "  - PostgreSQL:   localhost:$POSTGRES_PORT"
echo "  - Redis:        localhost:$REDIS_PORT"
echo ""
echo " Useful commands:"
echo "  - View all containers:  docker ps"
echo "  - View logs:            docker compose logs -f"
echo "  - View service logs:    docker compose logs -f <service>"
echo "  - Stop all services:    docker compose down"
echo ""
