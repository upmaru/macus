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

# The dependency must stay a released Hex package, never a sibling path.
if grep -nE '\{ *:opsmaru_incus *[^}]*(:path|:git|\.\.)' server/mix.exs; then
    echo "check-server: server/mix.exs references a non-Hex opsmaru_incus dependency" >&2
    exit 1
fi
source="$(sed -n 's/^  "opsmaru_incus": {:\([a-z]*\).*/\1/p' server/mix.lock)"
if [ "$source" != "hex" ]; then
    echo "check-server: server/mix.lock does not lock opsmaru_incus from Hex (found: ${source:-nothing})" >&2
    exit 1
fi

cd server
mise exec -- mix deps.get
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
