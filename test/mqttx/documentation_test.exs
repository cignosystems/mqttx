defmodule MqttX.DocumentationTest do
  @moduledoc """
  Checks the Elixir examples embedded in the project's Markdown documentation.

  Documentation examples are never executed by the compiler, so they rot
  silently — every doc defect found in the 0.11.0 review was of this kind: a
  landing-page example calling `transport: :thousand_island` (an atom where a
  module is required, raising `UndefinedFunctionError`), a `MqttX.Packet`
  module that did not exist, and stale option lists.

  These tests turn that class of rot into a CI failure. They deliberately do
  NOT execute the examples — most connect to a broker — but they do verify
  that every example parses, that every `MqttX.*` function it calls actually
  exists at that arity, and that transport options name real modules.
  """
  use ExUnit.Case, async: true

  @docs ["README.md", "AGENTS.md", "CONTRIBUTING.md"] ++ Path.wildcard("guides/*.md")

  # Examples that are intentionally illustrative rather than complete.
  @skip_markers ["# ...", "...", "$ ", "mix "]

  defp elixir_blocks(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({[], nil, 1, 1}, fn line, {blocks, buf, start, lineno} ->
      cond do
        buf == nil and String.trim(line) in ["```elixir", "```elixir\r"] ->
          {blocks, [], lineno + 1, lineno + 1}

        buf != nil and String.trim(line) == "```" ->
          {[{start, Enum.reverse(buf) |> Enum.join("\n")} | blocks], nil, start, lineno + 1}

        buf != nil ->
          {blocks, [line | buf], start, lineno + 1}

        true ->
          {blocks, buf, start, lineno + 1}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp skip?(code) do
    Enum.any?(@skip_markers, &String.contains?(code, &1)) or
      String.trim(code) == ""
  end

  describe "documentation examples" do
    test "every ```elixir block parses as valid Elixir" do
      failures =
        for path <- @docs,
            {line, code} <- elixir_blocks(path),
            not skip?(code),
            {:error, {meta, msg, token}} <- [safe_parse(code)] do
          detail = if is_binary(msg), do: msg, else: inspect(msg)
          "#{path}:#{line + Keyword.get(meta, :line, 0)} — #{detail}#{token}"
        end

      assert failures == [], "Unparseable documentation examples:\n" <> Enum.join(failures, "\n")
    end

    test "every MqttX function referenced in an example exists at that arity" do
      missing =
        for path <- @docs,
            {line, code} <- elixir_blocks(path),
            not skip?(code),
            {:ok, ast} <- [safe_parse(code)],
            {mod, fun, arity} <- mqttx_calls(ast),
            not exported?(mod, fun, arity) do
          "#{path}:~#{line} — #{inspect(mod)}.#{fun}/#{arity} does not exist"
        end

      assert missing == [],
             "Documentation references functions that do not exist:\n" <>
               Enum.join(Enum.uniq(missing), "\n")
    end

    test "transport: options name real transport modules, not bare atoms" do
      # The exact defect found on the MqttX landing page: `transport:
      # :thousand_island` raises UndefinedFunctionError because
      # MqttX.Server.start_link/3 calls `transport.start_link/3`.
      bad =
        for path <- @docs,
            {line, code} <- elixir_blocks(path),
            String.contains?(code, "MqttX.Server.start_link") or
              String.contains?(code, "transport: :"),
            [_, value] <- Regex.scan(~r/\btransport:\s*(:\w+)/, code),
            value not in ~w(:tcp :ssl :ws :wss) do
          "#{path}:~#{line} — transport: #{value} is not a module " <>
            "(use MqttX.Transport.ThousandIsland / .Ranch / .WebSocket)"
        end

      assert bad == [], "Invalid transport options in documentation:\n" <> Enum.join(bad, "\n")
    end

    test "dependency version in docs matches mix.exs" do
      {version, _} = Code.eval_string(File.read!("mix.exs") |> version_literal())
      [major, minor | _] = String.split(version, ".")

      stale =
        for path <- @docs,
            {_line, code} <- elixir_blocks(path),
            [match, declared] <- Regex.scan(~r/\{:mqttx,\s*"~>\s*([\d.]+)"/, code),
            not String.starts_with?(declared, "#{major}.#{minor}") do
          "#{path} — #{match} but mix.exs is #{version}"
        end

      assert stale == [],
             "Documentation pins an outdated version:\n" <> Enum.join(Enum.uniq(stale), "\n")
    end
  end

  # ---------- helpers ----------

  # Docs legitimately show bare options fragments (`ssl_opts: [verify: ...]`)
  # that only parse inside an enclosing list. Accept those, but still reject
  # genuinely malformed code.
  defp safe_parse(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, err} ->
        case Code.string_to_quoted("[" <> code <> "\n]") do
          {:ok, ast} -> {:ok, ast}
          {:error, _} -> {:error, err}
        end
    end
  end

  defp version_literal(mix_exs) do
    [_, v] = Regex.run(~r/@version\s+("[^"]+")/, mix_exs)
    v
  end

  # Collect remote calls to MqttX modules: {Module, :fun, arity}
  defp mqttx_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mod_parts}, fun]}, _, args} = node, acc ->
          mod = Module.concat(mod_parts)

          if mqttx_module?(mod) do
            {node, [{mod, fun, length(args)} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(calls)
  end

  defp mqttx_module?(mod) do
    mod |> Atom.to_string() |> String.starts_with?("Elixir.MqttX")
  end

  # Accept any arity within the function's default-argument range.
  defp exported?(mod, fun, arity) do
    Code.ensure_loaded?(mod) and
      Enum.any?(mod.__info__(:functions) ++ mod.__info__(:macros), fn {f, a} ->
        f == fun and a >= arity
      end)
  end

  describe "capacity numbers stay consistent between README and the guide" do
    # The README summarises figures whose method and caveats live in
    # guides/performance.md. Nothing kept the two in sync, and they had already
    # drifted: the README once advertised an unanchored "50,000 / 200,000"
    # ceiling while the guide documented up to ~1,000,000.

    test "each README instance row matches the guide's practical target" do
      guide = guide_instances()

      mismatches =
        for {instance, readme_idle, _chatty} <- readme_instances() do
          case Map.fetch(guide, instance) do
            {:ok, {_ceiling, practical}} when practical == readme_idle ->
              nil

            {:ok, {_ceiling, practical}} ->
              "#{instance}: README says ~#{fmt(readme_idle)} idle devices, " <>
                "guide's practical target is ~#{fmt(practical)}"

            :error ->
              "#{instance}: present in README but not in the guide's instance table"
          end
        end
        |> Enum.reject(&is_nil/1)

      assert readme_instances() != [], "no instance rows found in README — did the table move?"

      assert mismatches == [],
             "README and guides/performance.md disagree:\n" <> Enum.join(mismatches, "\n")
    end

    test "each README 'chatty devices' figure matches the guide's per-vCPU rate table" do
      rates = guide_message_rates()

      mismatches =
        for {instance, _idle, readme_chatty} <- readme_instances() do
          vcpu = vcpu_of(instance)

          case Map.fetch(rates, vcpu) do
            {:ok, at_1_per_sec} when at_1_per_sec == readme_chatty ->
              nil

            {:ok, at_1_per_sec} ->
              "#{instance}: README says ~#{fmt(readme_chatty)} devices @1 msg/s, " <>
                "guide's #{vcpu} vCPU row says ~#{fmt(at_1_per_sec)}"

            :error ->
              "#{instance}: no #{vcpu} vCPU row in the guide's message-rate table"
          end
        end
        |> Enum.reject(&is_nil/1)

      assert mismatches == [],
             "README and guides/performance.md disagree:\n" <> Enum.join(mismatches, "\n")
    end

    test "the guide's RAM-derived ceilings still match its published formula" do
      # guides/performance.md states: devices ~= (total_RAM * 0.60) / 22 KB
      drifted =
        for {instance, {ceiling, _practical}} <- guide_instances() do
          expected = trunc(gb_of(instance) * 1024 * 1024 * 0.60 / 22)
          # Ceilings are rounded for readability; allow 10%.
          if abs(ceiling - expected) / expected > 0.10 do
            "#{instance}: table says ~#{fmt(ceiling)}, formula gives ~#{fmt(expected)}"
          end
        end
        |> Enum.reject(&is_nil/1)

      assert drifted == [],
             "Guide ceilings no longer match the stated formula:\n" <> Enum.join(drifted, "\n")
    end
  end

  # ---------- capacity-table parsing ----------

  # README: | 1 vCPU / 2 GB | ~50,000 | ~15,000 | constraint |
  defp readme_instances do
    Regex.scan(
      ~r/^\|\s*(\d+ vCPU \/ \d+ GB)\s*\|\s*~([\d,]+)\s*\|\s*~([\d,]+)\s*\|/m,
      File.read!("README.md")
    )
    |> Enum.map(fn [_, instance, idle, chatty] ->
      {instance, num(idle), num(chatty)}
    end)
  end

  # Guide: | 1 vCPU / 2 GB | ~55,000 | ~50,000 | constraint |
  #        (instance | RAM-derived ceiling | practical target | constraint)
  defp guide_instances do
    Regex.scan(
      ~r/^\|\s*(\d+ vCPU \/ \d+ GB)\s*\|\s*~([\d,]+)\s*\|\s*~([\d,]+)\s*\|/m,
      File.read!("guides/performance.md")
    )
    |> Map.new(fn [_, instance, ceiling, practical] ->
      {instance, {num(ceiling), num(practical)}}
    end)
  end

  # Guide: | 1 vCPU | ~15,000 | ~1,500 |   (vCPU | @1 msg/s | @10 msg/s)
  defp guide_message_rates do
    Regex.scan(
      ~r/^\|\s*(\d+) vCPU\s*\|\s*~([\d,]+)\s*\|\s*~([\d,]+)\s*\|/m,
      File.read!("guides/performance.md")
    )
    |> Map.new(fn [_, vcpu, at_1, _at_10] -> {String.to_integer(vcpu), num(at_1)} end)
  end

  defp num(str), do: str |> String.replace(",", "") |> String.to_integer()
  defp fmt(n), do: n |> Integer.to_string() |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1,")
  defp vcpu_of(instance), do: instance |> String.split(" ") |> hd() |> String.to_integer()

  defp gb_of(instance) do
    [_, gb] = Regex.run(~r|/ (\d+) GB|, instance)
    String.to_integer(gb)
  end

  describe "CI matrix" do
    # The README quotes the CI matrix ("CI covers Elixir X-Y on OTP A-B");
    # bumping ci.yml without touching the README left it stale once already.

    test "the README's claimed version ranges match .github/workflows/ci.yml" do
      ci = File.read!(".github/workflows/ci.yml")

      elixirs =
        Regex.scan(~r/elixir:\s*'([\d.]+)'/, ci) |> Enum.map(fn [_, v] -> v end) |> Enum.uniq()

      otps = Regex.scan(~r/otp:\s*'(\d+)'/, ci) |> Enum.map(fn [_, v] -> v end) |> Enum.uniq()

      assert elixirs != [] and otps != [], "could not parse the CI matrix"

      claim =
        "CI covers Elixir #{Enum.min(elixirs)}-#{Enum.max(elixirs)} " <>
          "on OTP #{Enum.min(otps)}-#{Enum.max(otps)}"

      assert String.contains?(File.read!("README.md"), claim),
             "README's CI claim is stale — the matrix implies: \"#{claim}\""

      # mix.exs's floor must match the oldest pair CI still tests
      assert String.contains?(File.read!("mix.exs"), ~s(elixir: "~> #{Enum.min(elixirs)}")),
             "mix.exs elixir requirement no longer matches the oldest CI pair"
    end
  end

  describe "server callbacks" do
    # guides/server.md presents a "Callback Summary" table. It silently omitted
    # handle_puback/2 and handle_auth/3, so a reader building a broker could
    # not discover them.

    test "the callback summary lists exactly the callbacks the behaviour declares" do
      declared = MapSet.new(MqttX.Server.behaviour_info(:callbacks))

      documented =
        Regex.scan(~r/`(handle_\w+|init)\(([^)]*)\)`/, File.read!("guides/server.md"))
        |> Enum.map(fn [_, fun, args] ->
          arity = args |> String.split(",") |> Enum.count(&(String.trim(&1) != ""))
          {String.to_atom(fun), arity}
        end)
        |> MapSet.new()

      missing = MapSet.difference(declared, documented) |> Enum.sort()
      phantom = MapSet.difference(documented, declared) |> Enum.sort()

      assert missing == [],
             "Callbacks the behaviour declares but guides/server.md never shows: " <>
               inspect(missing)

      assert phantom == [],
             "guides/server.md documents callbacks that do not exist: " <> inspect(phantom)
    end
  end

  describe "telemetry events" do
    test "every event emitted by the library is documented in the telemetry guide" do
      documented = telemetry_events(["guides/telemetry.md", "README.md"])

      undocumented =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> telemetry_events()
        # `[:mqttx, ...]` and friends are typespec prefixes, not real events
        |> Enum.reject(&String.contains?(&1, "..."))
        |> Enum.reject(&MapSet.member?(documented, &1))

      assert undocumented == [],
             "Telemetry events emitted but not documented:\n" <> Enum.join(undocumented, "\n")
    end
  end

  describe "dependency requirements" do
    # The docs told users to add `{:websock_adapter, "~> 0.5"}` while mix.exs
    # allowed `"~> 0.5 or ~> 0.6"` — copying the doc snippet re-created the
    # exact resolution failure the widened requirement was meant to fix.

    test "optional-dependency snippets match the requirement in mix.exs" do
      required = mix_exs_deps()

      wrong =
        for path <- @docs,
            {dep, requirement} <- dep_snippets(path),
            Map.has_key?(required, dep),
            required[dep] != requirement do
          "#{path}: {:#{dep}, #{inspect(requirement)}} but mix.exs requires " <>
            inspect(required[dep])
        end

      assert wrong == [],
             "Documentation pins dependency versions mix.exs does not:\n" <>
               Enum.join(Enum.uniq(wrong), "\n")
    end

    test "the mqttx requirement is quoted identically everywhere" do
      quoted =
        for path <- @docs,
            {"mqttx", requirement} <- dep_snippets(path),
            do: {path, requirement}

      assert quoted != [], "no {:mqttx, ...} snippet found in the docs"

      distinct = quoted |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      assert length(distinct) == 1,
             "Docs recommend different mqttx requirements: #{inspect(quoted)}"
    end
  end

  describe "internal links" do
    # Every cross-document link in this repo is also a hexdocs URL. A heading
    # rename silently breaks them — this has happened twice.

    test "every relative link resolves to a real file and heading" do
      files = @docs ++ ["CHANGELOG.md"]

      anchors =
        Map.new(files, fn f -> {f, MapSet.new(headings(f), &slugify/1)} end)

      broken =
        for f <- files,
            {text, link} <- links(f),
            not String.starts_with?(link, ["http", "mailto:"]),
            {path, fragment} = split_link(link),
            target = resolve(f, path),
            problem = link_problem(target, fragment, anchors),
            problem != nil do
          "#{f}: [#{text}](#{link}) — #{problem}"
        end

      assert broken == [], "Broken documentation links:\n" <> Enum.join(broken, "\n")
    end

    test "no two headings in a guide share an anchor" do
      # ExDoc gives colliding headings the same id, so one of the two links
      # becomes unreachable. (CHANGELOG is exempt: repeated "### Fixed"
      # headings per release are the Keep a Changelog convention.)
      collisions =
        for f <- @docs,
            {slug, count} <- Enum.frequencies(Enum.map(headings(f), &slugify/1)),
            count > 1 do
          "#{f}: #{count} headings share the anchor ##{slug}"
        end

      assert collisions == [], "Colliding heading anchors:\n" <> Enum.join(collisions, "\n")
    end
  end

  describe "duplicated content stays consistent" do
    # Some duplication is deliberate: AGENTS.md is meant to be self-contained
    # for AI agents, and moduledocs must stand alone on their hexdocs page.
    # Those copies can't be removed, so they're pinned instead — this is what
    # let the handler-event list and the capacity tables drift apart before.

    test "codec benchmark figures agree wherever they are quoted" do
      figures =
        for path <- ["README.md", "guides/performance.md", "guides/codec.md"],
            File.exists?(path),
            into: %{} do
          nums =
            Regex.scan(
              ~r/\| (PUBLISH encode|SUBSCRIBE encode|PUBLISH decode) \| ([\d.]+)M/,
              File.read!(path)
            )
            |> Map.new(fn [_, op, val] -> {op, val} end)

          {path, nums}
        end

      quoted = Enum.reject(figures, fn {_p, nums} -> nums == %{} end)

      case quoted do
        [] ->
          flunk("no benchmark figures found — did the tables move?")

        [{_first_path, reference} | rest] ->
          mismatches =
            for {path, nums} <- rest, {op, val} <- nums, reference[op] != val do
              "#{path}: #{op} = #{val}M but reference says #{reference[op]}M"
            end

          assert mismatches == [],
                 "Benchmark figures disagree across docs:\n" <> Enum.join(mismatches, "\n")
      end
    end

    test "every handler event the connection emits is documented" do
      # Derived from the source, not hardcoded: adding a fifth event without
      # documenting it should fail here.
      events =
        Regex.scan(
          ~r/notify_handler\(\s*state,?\s*:(\w+)/,
          File.read!("lib/mqttx/client/connection.ex")
        )
        |> Enum.map(fn [_, event] -> ":" <> event end)
        |> Enum.uniq()

      assert length(events) >= 4, "expected to find the handler events in connection.ex"

      # guides/client.md is canonical; AGENTS.md is deliberately self-contained.
      incomplete =
        for path <- ["guides/client.md", "AGENTS.md"],
            content = File.read!(path),
            missing = Enum.reject(events, &String.contains?(content, &1)),
            missing != [] do
          "#{path} omits #{Enum.join(missing, ", ")}"
        end

      assert incomplete == [],
             "Handler events emitted but not documented:\n" <> Enum.join(incomplete, "\n")
    end

    test "the connect-option tables in README and the client guide agree" do
      readme = connect_option_table("README.md")
      guide = connect_option_table("guides/client.md")

      assert map_size(readme) > 10, "no connect-option table found in README"
      assert map_size(guide) > 10, "no connect-option table found in guides/client.md"

      only_readme = Map.keys(readme) -- Map.keys(guide)
      only_guide = Map.keys(guide) -- Map.keys(readme)

      assert only_readme == [], "options in README but not the guide: #{inspect(only_readme)}"
      assert only_guide == [], "options in the guide but not README: #{inspect(only_guide)}"

      differing =
        for {opt, default} <- readme,
            guide[opt] != default,
            do: "#{opt}: README says #{default}, guide says #{guide[opt]}"

      assert differing == [],
             "Documented defaults disagree:\n" <> Enum.join(differing, "\n")
    end

    test "the use MqttX callback set is described identically wherever it is listed" do
      callbacks = ~w(init/1 handle_message/4 handle_connected/2 handle_disconnected/2
                     handle_publish_error/4 handle_info/2)

      # guides/client.md and MqttX.SimpleClient are the canonical descriptions;
      # both must name the full set.
      for path <- ["guides/client.md", "lib/mqttx/simple_client.ex"] do
        content = File.read!(path)

        missing =
          Enum.reject(callbacks, fn cb ->
            [name, arity] = String.split(cb, "/")
            String.contains?(content, name) and String.contains?(content, arity)
          end)

        assert missing == [], "#{path} omits callbacks: #{Enum.join(missing, ", ")}"
      end
    end
  end

  # Rows of the "Connect Options" table: option name -> documented default.
  defp connect_option_table(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(not String.contains?(&1, "Connect Options")))
    |> Enum.drop_while(&(not String.starts_with?(&1, "| `:")))
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.flat_map(fn row ->
      case String.split(row, "|", trim: true) do
        [opt, _desc, default] -> [{String.trim(opt), String.trim(default)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp headings(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_fence?} ->
      cond do
        String.starts_with?(String.trim(line), "```") ->
          {acc, not in_fence?}

        in_fence? ->
          {acc, in_fence?}

        true ->
          case Regex.run(~r/^\#{1,6}\s+(.+)$/, line) do
            [_, title] -> {[title | acc], in_fence?}
            nil -> {acc, in_fence?}
          end
      end
    end)
    |> elem(0)
  end

  # Mirrors ExDoc/GitHub heading slugification closely enough to catch renames.
  defp slugify(title) do
    title
    |> String.replace("`", "")
    |> String.trim()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.downcase()
    |> String.replace(~r/[\s_]+/, "-")
    |> String.trim("-")
  end

  defp links(path) do
    Regex.scan(~r/\[([^\]]*)\]\(([^)\s]+)\)/, File.read!(path))
    |> Enum.map(fn [_, text, link] -> {text, link} end)
  end

  defp split_link(link) do
    case String.split(link, "#", parts: 2) do
      [path] -> {path, nil}
      [path, fragment] -> {path, fragment}
    end
  end

  defp resolve(from, ""), do: from
  defp resolve(from, path), do: Path.expand(path, Path.dirname(from)) |> Path.relative_to_cwd()

  defp link_problem(target, fragment, anchors) do
    cond do
      not File.exists?(target) -> "file #{target} does not exist"
      fragment in [nil, ""] -> nil
      not Map.has_key?(anchors, target) -> nil
      MapSet.member?(anchors[target], fragment) -> nil
      true -> "no heading anchor ##{fragment} in #{target}"
    end
  end

  # {:dep, "req"} pairs quoted in a doc's dependency snippets.
  defp dep_snippets(path) do
    Regex.scan(~r/\{:(\w+),\s*"([^"]+)"[,}]/, File.read!(path))
    |> Enum.map(fn [_, dep, req] -> {dep, req} end)
    |> Enum.uniq()
  end

  defp mix_exs_deps do
    Regex.scan(~r/\{:(\w+),\s*"([^"]+)"/, File.read!("mix.exs"))
    |> Map.new(fn [_, dep, req] -> {dep, req} end)
  end

  defp telemetry_events(paths) do
    paths
    |> Enum.flat_map(fn path ->
      Regex.scan(~r/\[:mqttx[^\]]*\]/, File.read!(path))
      |> Enum.map(fn [event] -> String.replace(event, " ", "") end)
    end)
    |> MapSet.new()
  end
end
