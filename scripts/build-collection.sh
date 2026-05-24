#!/usr/bin/env bash
set -euo pipefail

COLLECTION_DIR="/opt/ansible/collections/ansible_collections/openclaw/node"
BUILD_DIR="/opt/ansible/dist"

mkdir -p "$BUILD_DIR"

echo "🧱 Building Ansible Collection..."

cd "$COLLECTION_DIR"

ansible-galaxy collection build \
  --output-path "$BUILD_DIR"

echo "✅ Build complete:"
ls -lh "$BUILD_DIR"
