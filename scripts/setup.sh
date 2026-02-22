#!/bin/bash

# Script to clone the frontend and backend repositories for the coding platform

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "📥 Setting up Coding Platform Repositories"
echo "================================================"
echo ""

cd "$PROJECT_ROOT"

# Create src directory if it doesn't exist
mkdir -p src

# Clone or update backend
echo "⚙️  Setting up Backend..."
if [ -d "src/backend/.git" ]; then
    echo "Backend repository already exists. Pulling latest changes..."
    cd src/backend
    git pull origin main || git pull origin master
    cd "$PROJECT_ROOT"
else
    echo "Cloning backend repository..."
    # Remove empty directory if it exists
    if [ -d "src/backend" ] && [ -z "$(ls -A src/backend)" ]; then
        rm -rf src/backend
    fi
    git clone https://github.com/jshishimaru/coding-platform-backend.git src/backend
fi
echo "✅ Backend setup complete."
echo ""

# Clone or update frontend
echo "🎨 Setting up Frontend..."
if [ -d "src/frontend/.git" ]; then
    echo "Frontend repository already exists. Pulling latest changes..."
    cd src/frontend
    git pull origin main || git pull origin master
    cd "$PROJECT_ROOT"
else
    echo "Cloning frontend repository..."
    # Remove empty directory if it exists
    if [ -d "src/frontend" ] && [ -z "$(ls -A src/frontend)" ]; then
        rm -rf src/frontend
    fi
    git clone https://github.com/jshishimaru/coding-platform-frontend.git src/frontend
fi
echo "✅ Frontend setup complete."
echo ""

echo "================================================"
echo "🎉 Setup Complete!"
echo ""
echo "You can now build and run the platform using:"
echo "  ./scripts/build.sh"
echo "  ./scripts/run.sh"
echo ""
