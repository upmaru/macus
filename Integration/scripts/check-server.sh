#!/bin/sh
# Pinned Mix gates for the headless Elixir server (task 10.1).
#
# Runs the same gates the CI server job used to run, through the mise-pinned
# Elixir/OTP toolchain, so the canonical root check covers the server too:
# dependency resolution, strict formatting, warning-free compilation and the
# full fixture-only test suite (gateway, proxy, MCP, dex, release).
#
# The locked opsmaru_incus is a released Hex package. A sibling ../opsmaru-incus
# checkout is never an input: the guard below fails before any Mix command if
# server/mix.exs or server/mix.lock references a path or git dependency for it.
# Everything here is fixture-only; no listener, VM, state or download beyond
# `mix deps.get` resolving the locked Hex packages.
set -eu

cd "$(dirname "$0")/../.."
root="$PWD"

# The dependency must stay a released Hex package, never a sibling path or a
# git revision. Mix dependencies use keyword syntax, so catch every form:
#   {:opsmaru_incus, path: "../opsmaru-incus"}
#   {:opsmaru_incus, git: "..."}
#   {:opsmaru_incus, github: "upmaru/opsmaru-incus"}
# plus any literal "../" on the dependency line.
guard_hex_dependency() {
    project_root="$1"
    if grep -nE '\{ *:opsmaru_incus *[^}]*(\.\.|[ (](path|git|github):)' "$project_root/server/mix.exs"; then
        echo "check-server: $project_root/server/mix.exs references a non-Hex opsmaru_incus dependency" >&2
        return 1
    fi
    source="$(sed -n 's/^  "opsmaru_incus": {:\([a-z]*\).*/\1/p' "$project_root/server/mix.lock")"
    if [ "$source" != "hex" ]; then
        echo "check-server: $project_root/server/mix.lock does not lock opsmaru_incus from Hex (found: ${source:-nothing})" >&2
        return 1
    fi
}

# `check-server.sh --guard-only PROJECT_ROOT` runs only the guard, so a copy
# of the manifest can be pointed at without running Mix.
if [ "${1:-}" = "--guard-only" ]; then
    guard_hex_dependency "${2:?usage: check-server.sh [--guard-only PROJECT_ROOT]}"
    exit 0
fi

guard_hex_dependency "$root"

cd server
mise exec -- mix deps.get
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
