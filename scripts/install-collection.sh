#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="/opt/ansible/dist"

LATEST=$(ls -t "$BUILD_DIR"/openclaw-node-*.tar.gz | head -n 1)

echo "📦 Installing $LATEST"

ansible-galaxy collection install "$LATEST" -p ~/.ansible/collections --force

echo "✅ Installed collection"
