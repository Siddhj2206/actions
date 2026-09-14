#!/usr/bin/env bats
# Tests for the bootc-build/chunka config-file setup.
#
# Regression guard for the fs.protected_regular failure introduced when the
# inspect JSON was moved from argv to a file (#473). The config temp file lives
# in /var/tmp, a world-writable sticky directory (1777). If it is created by the
# unprivileged runner user, the later `sudo tee` (root) opens a file that belongs
# to neither root nor the directory owner, and the kernel's may_create_in_sticky
# check (fs/namei.c) returns EACCES -- "tee: ...: Permission denied".
#
# The fix is to create the file with `sudo mktemp` so root owns it from the start.
#
# The snippet below is the config-file excerpt from the "Rechunk with chunkah"
# run block in bootc-build/chunka/action.yml, plus `set -euo pipefail` as at the
# top of that block. A drift guard at the bottom pins the action to it.
#
# sudo and podman are stubbed on PATH so no container runtime or privilege is
# required. mktemp is NOT stubbed: the test exercises the real template and path.

CHUNKAH_CONFIG_SNIPPET=$(cat <<'SNIP'
set -euo pipefail

CHUNKAH_CONFIG_FILE="$(sudo mktemp -p /var/tmp chunkah-config.XXXXXX.json)"
sudo podman inspect "${SOURCE}" --format '{{json .Config}}' | sudo tee "${CHUNKAH_CONFIG_FILE}" > /dev/null
sudo chmod 644 "${CHUNKAH_CONFIG_FILE}"
SNIP
)

setup() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP
  export STUB_BIN="${TEST_TMP}/bin"
  mkdir -p "$STUB_BIN"
  export CMD_LOG="${TEST_TMP}/cmd.log"
  : >"$CMD_LOG"

  # Pass-through sudo mock: log the invocation, then run the command unprivileged.
  cat >"${STUB_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$CMD_LOG"
"$@"
STUB
  chmod +x "${STUB_BIN}/sudo"

  # podman mock: emit a small inspect JSON payload.
  cat >"${STUB_BIN}/podman" <<'STUB'
#!/usr/bin/env bash
echo "podman $*" >>"$CMD_LOG"
printf '%s\n' '{"Labels":{"containers.bootc":"1"}}'
STUB
  chmod +x "${STUB_BIN}/podman"

  export PATH="${STUB_BIN}:${PATH}"
  export SOURCE="localhost/bluefin:latest"
}

teardown() {
  rm -rf "$TEST_TMP"
  rm -f /var/tmp/chunkah-config.*.json 2>/dev/null || true
}

# ── Root-owned creation ───────────────────────────────────────────────────────

@test "chunka: config temp file is created through sudo so root owns it" {
  run bash -c "$CHUNKAH_CONFIG_SNIPPET"
  [ "$status" -eq 0 ]

  # The regression: a bare `mktemp` would leave no "sudo mktemp" entry.
  run grep -qE '^sudo mktemp -p /var/tmp chunkah-config\.XXXXXX\.json$' "$CMD_LOG"
  [ "$status" -eq 0 ]
}

@test "chunka: inspect JSON is piped through sudo tee into the config file" {
  run bash -c "$CHUNKAH_CONFIG_SNIPPET"
  [ "$status" -eq 0 ]

  run grep -qE '^sudo tee /var/tmp/chunkah-config\.[A-Za-z0-9]+\.json$' "$CMD_LOG"
  [ "$status" -eq 0 ]

  run grep -qE '^sudo chmod 644 /var/tmp/chunkah-config\.[A-Za-z0-9]+\.json$' "$CMD_LOG"
  [ "$status" -eq 0 ]
}

@test "chunka: config temp file ends up containing the inspect JSON" {
  run bash -c "$CHUNKAH_CONFIG_SNIPPET"
  [ "$status" -eq 0 ]

  local config_file
  config_file=$(find /var/tmp -maxdepth 1 -name 'chunkah-config.*.json' -print -quit)
  [ -n "$config_file" ]
  [ -f "$config_file" ]
  grep -q '"containers.bootc":"1"' "$config_file"
}

# ── Drift guard against action.yml ────────────────────────────────────────────

@test "chunka: action.yml creates the config temp file with sudo mktemp" {
  ACTION="${BATS_TEST_DIRNAME}/../../bootc-build/chunka/action.yml"
  [ -f "$ACTION" ]

  # Positive: the fixed line is present.
  # shellcheck disable=SC2016
  grep -qF 'CHUNKAH_CONFIG_FILE="$(sudo mktemp -p /var/tmp chunkah-config.XXXXXX.json)"' "$ACTION"

  # Negative: the pre-fix (runner-owned) line is gone. This is the guard that
  # fails if someone reverts to a bare `mktemp`.
  # shellcheck disable=SC2016
  if grep -qF 'CHUNKAH_CONFIG_FILE="$(mktemp -p /var/tmp chunkah-config.XXXXXX.json)"' "$ACTION"; then
    echo "action.yml still contains the pre-fix bare mktemp line" >&2
    return 1
  fi
}
