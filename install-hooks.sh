#!/usr/bin/env bash
#
# install-hooks.sh
#
# Sets up GitHub Actions self-hosted runner job hooks under /opt/actions-runner.
# Creates:
#   hooks/run-hooks.sh          - dispatcher (runs every *.sh in a phase dir)
#   hooks/on-started.sh         - no-arg wrapper -> run-hooks.sh started
#   hooks/on-completed.sh       - no-arg wrapper -> run-hooks.sh completed
#   hooks/started.d/10-diagnostics.sh
#   hooks/started.d/20-disk-guard.sh
#   hooks/completed.d/10-cleanup.sh
# And registers the hook env vars in /opt/actions-runner/.env
#
# Run once on the runner host:  sudo bash install-hooks.sh
# Then restart the runner service so it picks up .env:
#   cd /opt/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh start
#
set -euo pipefail

RUNNER_DIR="/opt/actions-runner"
HOOKS_DIR="$RUNNER_DIR/hooks"
ENV_FILE="$RUNNER_DIR/.env"

if [ ! -d "$RUNNER_DIR" ]; then
  echo "ERROR: $RUNNER_DIR does not exist. Is the runner installed there?" >&2
  exit 1
fi

echo "Creating hook directories under $HOOKS_DIR"
mkdir -p "$HOOKS_DIR/started.d" "$HOOKS_DIR/completed.d"

# ----------------------------------------------------------------------------
# dispatcher
# ----------------------------------------------------------------------------
cat > "$HOOKS_DIR/run-hooks.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Runs every executable *.sh in the phase directory, in filename order.
set -uo pipefail
phase="${1:?usage: run-hooks.sh <started|completed>}"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${phase}.d"
[ -d "$dir" ] || { echo "[hooks] no $dir, nothing to run"; exit 0; }
rc=0
for script in "$dir"/*.sh; do
  [ -e "$script" ] || continue
  [ -x "$script" ] || continue
  echo "::group::[hooks] $phase -> $(basename "$script")"
  if ! "$script"; then
    echo "[hooks] $(basename "$script") exited non-zero"
    rc=1
  fi
  echo "::endgroup::"
done
exit "$rc"
SCRIPT

# ----------------------------------------------------------------------------
# no-arg wrappers (runner versions that don't accept args in the hook var)
# ----------------------------------------------------------------------------
cat > "$HOOKS_DIR/on-started.sh" <<'SCRIPT'
#!/usr/bin/env bash
exec "$(dirname "${BASH_SOURCE[0]}")/run-hooks.sh" started
SCRIPT

cat > "$HOOKS_DIR/on-completed.sh" <<'SCRIPT'
#!/usr/bin/env bash
exec "$(dirname "${BASH_SOURCE[0]}")/run-hooks.sh" completed
SCRIPT

# ----------------------------------------------------------------------------
# started.d/10-diagnostics.sh
# ----------------------------------------------------------------------------
cat > "$HOOKS_DIR/started.d/10-diagnostics.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
echo "==================================================="
echo "[pre-job] Runner diagnostics - $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "==================================================="
echo "--- Job context ---"
echo "Repo:      ${GITHUB_REPOSITORY:-n/a}"
echo "Workflow:  ${GITHUB_WORKFLOW:-n/a}"
echo "Run ID:    ${GITHUB_RUN_ID:-n/a}"
echo "Runner:    ${RUNNER_NAME:-n/a}"
echo "Workspace: ${GITHUB_WORKSPACE:-n/a}"
echo "--- Host ---"
echo "Hostname:  $(hostname)"
echo "Kernel:    $(uname -srm)"
[ -f /etc/os-release ] && . /etc/os-release && echo "OS:        ${PRETTY_NAME:-unknown}"
echo "Uptime:    $(uptime -p 2>/dev/null || uptime)"
echo "--- CPU / Memory ---"
echo "CPUs:      $(nproc)"
echo "Load avg:  $(awk '{print $1, $2, $3}' /proc/loadavg)"
free -h 2>/dev/null || vm_stat 2>/dev/null || true
echo "--- Disk ---"
df -h "${GITHUB_WORKSPACE:-/}" "${RUNNER_TEMP:-/tmp}" / 2>/dev/null | sort -u
echo "--- Docker ---"
if command -v docker >/dev/null 2>&1; then
  docker version --format '  Client: {{.Client.Version}}  Server: {{.Server.Version}}' 2>/dev/null || echo "  docker present but daemon unreachable"
  echo "  Containers running: $(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
  echo "  Images:             $(docker images -q 2>/dev/null | wc -l | tr -d ' ')"
else
  echo "  not installed"
fi
echo "--- Key tooling ---"
for t in git node npm python3 go java dotnet az; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  %-8s %s\n' "$t" "$("$t" --version 2>&1 | head -n1)"
  else
    printf '  %-8s %s\n' "$t" "NOT FOUND"
  fi
done
echo "==================================================="
SCRIPT

# ----------------------------------------------------------------------------
# started.d/20-disk-guard.sh
# ----------------------------------------------------------------------------
cat > "$HOOKS_DIR/started.d/20-disk-guard.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
MIN_KB=2097152  # 2 GB
target="${GITHUB_WORKSPACE:-/}"
avail_kb=$(df --output=avail "$target" 2>/dev/null | tail -n1 | tr -d ' ')
if [ -z "${avail_kb:-}" ]; then
  echo "[disk-guard] WARNING: could not read free space on $target, skipping check"
  exit 0
fi
avail_gb=$(( avail_kb / 1024 / 1024 ))
echo "[disk-guard] ${avail_gb}GB free on $target"
if [ "$avail_kb" -lt "$MIN_KB" ]; then
  echo "[disk-guard] ERROR: below 2GB free - failing job to avoid a doomed run" >&2
  exit 1
fi
SCRIPT

# ----------------------------------------------------------------------------
# completed.d/10-cleanup.sh
# ----------------------------------------------------------------------------
cat > "$HOOKS_DIR/completed.d/10-cleanup.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
WORKSPACE="${GITHUB_WORKSPACE:-}"
echo "[cleanup] Job completed hook for ${GITHUB_REPOSITORY:-unknown}"
if [ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ]; then
  echo "[cleanup] Cleaning workspace: $WORKSPACE"
  if [ -d "$WORKSPACE/.git" ]; then
    git -C "$WORKSPACE" clean -ffdx || true
    git -C "$WORKSPACE" reset --hard || true
  fi
  find "$WORKSPACE" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi
rm -rf "${RUNNER_TEMP:-/tmp}"/* 2>/dev/null || true
# Aggressive: prunes ALL unused Docker resources on this host.
# Remove this block if the runner is shared across repos/projects.
if command -v docker >/dev/null 2>&1; then
  docker system prune -af --volumes || true
fi
echo "[cleanup] Done."
SCRIPT

# ----------------------------------------------------------------------------
# permissions
# ----------------------------------------------------------------------------
chmod +x "$HOOKS_DIR/run-hooks.sh" \
         "$HOOKS_DIR/on-started.sh" \
         "$HOOKS_DIR/on-completed.sh" \
         "$HOOKS_DIR/started.d/"*.sh \
         "$HOOKS_DIR/completed.d/"*.sh

# ----------------------------------------------------------------------------
# .env registration (idempotent: strip any prior hook lines first)
# ----------------------------------------------------------------------------
touch "$ENV_FILE"
sed -i '/^ACTIONS_RUNNER_HOOK_JOB_STARTED=/d;/^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/d' "$ENV_FILE"
{
  echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$HOOKS_DIR/on-started.sh"
  echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$HOOKS_DIR/on-completed.sh"
} >> "$ENV_FILE"

echo
echo "Done. Layout created under $HOOKS_DIR:"
echo "  run-hooks.sh, on-started.sh, on-completed.sh"
echo "  started.d/10-diagnostics.sh, started.d/20-disk-guard.sh"
echo "  completed.d/10-cleanup.sh"
echo
echo "Registered in $ENV_FILE:"
grep '^ACTIONS_RUNNER_HOOK_JOB_' "$ENV_FILE"
echo
echo "Now restart the runner service to load .env:"
echo "  cd $RUNNER_DIR && sudo ./svc.sh stop && sudo ./svc.sh start"
