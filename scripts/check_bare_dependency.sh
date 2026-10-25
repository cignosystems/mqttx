#!/usr/bin/env sh
# mqttx as a dependency of a project that has none of its optional packages
# (thousand_island, ranch, bandit, websock_adapter, protox) must compile
# without a warning. Run from anywhere; exits non-zero on a warning or error.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

cd "$dir"
mix new bare_dep >/dev/null
cat > bare_dep/mix.exs <<MIX
defmodule BareDep.MixProject do
  use Mix.Project

  def project do
    [app: :bare_dep, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps, do: [{:mqttx, path: "$repo"}]
end
MIX

cd bare_dep
mix deps.get >/dev/null
mix deps.compile 2>&1 | tee compile.log

if grep -qE "warning:|error:|\*\* \(" compile.log; then
  echo "mqttx did not compile cleanly as a bare dependency (see above)" >&2
  exit 1
fi

echo "mqttx compiles cleanly as a bare dependency"
