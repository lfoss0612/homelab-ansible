set -euo pipefail

# Make sure pnpm is available
which pnpm || corepack enable
corepack prepare pnpm@latest --activate
pnpm -v

# Clone/download source
cd /tmp
sudo rm -rf openclaw-build openclaw-build.tar.gz
sudo curl -fsSL -o openclaw-build.tar.gz \
  https://github.com/openclaw/openclaw/archive/refs/tags/2026.5.12.tar.gz

sudo mkdir
openclaw-build
sudo tar xzf openclaw-build.tar.gz -C openclaw-build --strip-components=1
cd /tmp/openclaw-build

# Install + build
sudo pnpm install --frozen-lockfile 2>&1 | tee /tmp/openclaw-install.log | tail -20
sudo pnpm run build 2>&1 | tee /tmp/openclaw-build.log | tail -20

# Verify artifacts
ls -la dist/ | head
test -f dist/index.js && echo "dist/index.js OK"
test -f openclaw.mjs && echo "openclaw.mjs OK"

# Prune to prod deps only (this wiped+reinstalled last time; with 8 GB it should breeze through)
sudo pnpm prune --prod
sudo du -sh node_modules/

# Package the runtime
sudo tar czf /tmp/openclaw-runtime-2026.5.12.tar.gz \
  openclaw.mjs package.json pnpm-workspace.yaml \
  dist/ \
  $(test -d dist-runtime && echo dist-runtime/) \
  scripts/ \
  $(test -d patches && echo patches/) \
  $(test -d skills && echo skills/) \
  node_modules/

ls -lh /tmp/openclaw-runtime-2026.5.12.tar.gz
