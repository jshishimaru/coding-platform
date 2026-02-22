#!/bin/bash

# Script to build Docker images for the coding platform
# Builds all services using docker compose

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔨 Building Coding Platform Docker Images"
echo "================================================"
echo ""

cd "$PROJECT_ROOT"

# Build all services
echo "📦 Building all service images..."
echo ""

docker compose build

echo ""
echo "================================================"
echo "✅ Build Complete!"
echo ""
echo "📋 Built images:"
docker images | grep -E "coding-platform|REPOSITORY" || true
echo ""
echo "To start all services:"
echo "  ./scripts/run.sh"
echo ""
