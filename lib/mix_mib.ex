defmodule Mix.Tasks.Compile.Mibs do
  use Mix.Task
  require Record

  Record.defrecordp :mib_def, :pdata, Record.extract(:pdata, from_lib: "snmp/src/compiler/snmpc.hrl")

  @recursive true
  @manifest ".compile.mibs"

  def manifests, do: [manifest()]
  defp manifest, do: Path.join(Mix.Project.manifest_path(), @manifest)

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [force: :boolean])
    verbose = opts[:verbose]

    project = Mix.Project.config
    mibs_paths = project[:mibs_paths] || ["mibs", "src"]

    mibs_output  = project[:mibs_output] || "priv/mibs"
    hrls_output  = project[:erlc_include_path] || "include"

    mibs_options = project[:mibs_options] || [il: ['otp_mibs/priv/mibs']]
    mibs_options = [outdir: to_charlist(mibs_output),
                    i: [to_charlist(mibs_output)]
                   ] ++ mibs_options

    files = Mix.Utils.extract_files(mibs_paths, ["mib"])

    entries = files |>
      Enum.map(&to_entity(&1, mibs_output, hrls_output)) |>
      sort_dependencies()

    entries = if opts[:force] do
      entries
    else
      set_stale(entries, MapSet.new())
    end

    stale_bins = for entry = %{bin_stale: true} <- entries, do: entry
    stale_hrls = for entry = %{hrl_stale: true} <- entries, do: entry

    save = :lists.usort(Enum.flat_map(entries, fn(%{bin: bin, hrl: hrl}) ->
          [bin, hrl]
        end))

    # Remove the files that were produced for previous set of sources
    Enum.each(read_manifest() -- save, &File.rm/1)

    # Write the files being produced so they can be correctly removed
    # if compilation fails
    write_manifest(save)

    results = if stale_bins == [] && stale_hrls == [] do
      []
    else
      File.mkdir_p!(mibs_output)
      File.mkdir_p!(hrls_output)
      Mix.Project.ensure_structure()

      if stale_bins == [] do
        []
      else
        Mix.Utils.compiling_n(length(stale_bins), :mib)
        for %{mib: mib} <- stale_bins do
          verbose && Mix.shell.info("Compiling #{mib}")
          do_compile_mib(mib, mibs_options)
        end
      end
      ++
      if stale_hrls == [] do
        []
      else
        Mix.shell.info "Generating #{length(stale_hrls)} files (.hrl)"
        for %{bin: bin, hrl: hrl} <- stale_hrls do
          verbose && Mix.shell.info("Generating #{hrl}")
          do_compile_hrl(bin, hrl)
        end
      end
    end

    if :error in results do
      Mix.raise "Encountered compilation errors"
    else
      :ok
    end
  end

  defp set_stale([entity | entities], stale) do
    mib = entity.mib
    funcs = entity.funcs
    bin = entity.bin
    hrl = entity.hrl

    cond do
      Enum.any?(entity.deps, &(MapSet.member?(stale, &1))) || Mix.Utils.stale?([mib, funcs], [bin]) ->
        [entity | set_stale(entities, MapSet.put(stale, entity.id))]

      Mix.Utils.stale?([bin], [hrl]) ->
        [%{entity | bin_stale: false}
         | set_stale(entities, stale)]

      true ->
        [%{entity |
           bin_stale: false,
           hrl_stale: false}
         | set_stale(entities, stale)]
    end
  end
  defp set_stale([], _), do: []

  defp do_compile_mib(mib, mibs_options) do
    try do
      :snmpc.compile(to_charlist(mib), mibs_options)
      :ok
    catch
      :exit, reason ->
        Mix.shell.error("Error while compiling #{mib}: #{reason}")
        :error
    end
  end

  defp do_compile_hrl(bin, hrl) do
    basename = bin |> Path.basename() |> Path.rootname()
    case :snmpc_mib_to_hrl.convert(to_charlist(bin), to_charlist(hrl), to_charlist(basename)) do
      :ok ->
        :ok
      {:error, reason} ->
        Mix.shell.error("Error while generating #{hrl}: #{reason}")
        :error
    end
  end

  def clean do
    Mix.Compilers.Erlang.clean(manifest())
  end

  defp read_manifest do
    case File.read(manifest()) do
      {:ok, contents} -> String.split(contents, "\n")
      {:error, _} -> []
    end
  end

  defp write_manifest(entries) do
    file = manifest()
    Path.dirname(file) |> File.mkdir_p!
    File.write!(file, Enum.join(entries, "\n"))
  end

  defp to_entity(mib, mibs_output, hrls_output) do
    rootname = Path.rootname(mib, ".mib")
    funcs = rootname <> ".funcs"
    basename = Path.basename(rootname)
    bin = Path.join(mibs_output, basename) <> ".bin"
    hrl = Path.join(hrls_output, basename) <> ".hrl"

    case parse_mib(mib) do
      {:ok, mib_def(mib_name: id, imports: imports)} ->
        deps = Enum.map(imports, &import_getter/1)
        %{mib: mib,
          funcs: funcs,
          bin: bin,
          hrl: hrl,
          id: id,
          bin_stale: true,
          hrl_stale: true,
          deps: deps}

      _error ->
        # pretend the file will be compiled somehow
        id = String.to_atom(Path.basename(rootname))
        %{mib: mib,
          funcs: funcs,
          bin: bin,
          hrl: hrl,
          id: id,
          bin_stale: true,
          hrl_stale: true,
          deps: []}
    end
  end

  defp import_getter({{import_name, _}, _}), do: import_name

  # reworked version of snmp-5.1.1/src/compiler/snmpc.erl
  defp parse_mib(file) do
    case tokenize_mib(file) do
      tokens when is_list(tokens) ->
        parse_mib_tokens(tokens)
      error ->
        error
    end
  end

  defp tokenize_mib(file) do
    case :snmpc_tok.start_link(reserved_words(),
          [file: to_charlist(file),
           forget_stringdata: true]) do
      {:ok, tokPid} ->
        toks = :snmpc_tok.get_all_tokens(tokPid)
        :snmpc_tok.stop(tokPid)
        toks
      {:error, _reason} = error ->
        error
    end
  end

  defp parse_mib_tokens(toks) do
    # MODULE-IDENTITY _must_ be invoked in SNMPv2 according to RFC1908
    old_snmp_version = Process.put(:snmp_version,
      case List.keymember?(toks, :'MODULE-IDENTITY', 0) do
        true -> 2
        _ -> 1
      end)

    try do
      :snmpc_mib_gram.parse(toks)
    after
      Process.put(:snmp_version, old_snmp_version)
    end
  end

  # copied from snmp-5.1.1/src/compiler/snmpc.erl
  defp reserved_words, do: [
    :'ACCESS', :'BEGIN', :'BIT', :'CONTACT-INFO', :'Counter', :'DEFINITIONS',
    :'DEFVAL', :'DESCRIPTION', :'DISPLAY-HINT', :'END', :'ENTERPRISE',
    :'FROM', :'Gauge', :'IDENTIFIER', :'IDENTIFIER', :'IMPORTS', :'INDEX',
    :'INTEGER', :'IpAddress', :'LAST-UPDATED', :'NetworkAddress', :'OBJECT',
    :'OBJECT', :'OBJECT-TYPE', :'OCTET', :'OF', :'Opaque', :'REFERENCE',
    :'SEQUENCE', :'SIZE', :'STATUS', :'STRING', :'SYNTAX', :'TRAP-TYPE',
    :'TimeTicks', :'VARIABLES',

    # v2
    :'LAST-UPDATED', :'ORGANIZATION', :'CONTACT-INFO', :'MODULE-IDENTITY',
    :'NOTIFICATION-TYPE', :'MODULE-COMPLIANCE', :'OBJECT-GROUP',
    :'NOTIFICATION-GROUP', :'REVISION', :'OBJECT-IDENTITY', :'MAX-ACCESS',
    :'UNITS', :'AUGMENTS', :'IMPLIED', :'OBJECTS', :'TEXTUAL-CONVENTION',
    :'OBJECT-GROUP', :'NOTIFICATION-GROUP', :'NOTIFICATIONS',
    :'MODULE-COMPLIANCE', :'AGENT-CAPABILITIES', :'PRODUCT-RELEASE',
    :'SUPPORTS', :'INCLUDES', :'MODULE', :'MANDATORY-GROUPS', :'GROUP',
    :'WRITE-SYNTAX', :'MIN-ACCESS', :'BITS'
  ]

  defp sort_dependencies(entities) do
    graph = :digraph.new

    _ = for entity <- entities do
      # store whole entity as a label
      :digraph.add_vertex(graph, entity.id, entity)
    end

    _ = for entity <- entities do
      current = entity.id
      _ = for dep <- entity.deps, do: :digraph.add_edge(graph, dep, current)
    end

    result = case :digraph_utils.topsort(graph) do
               false -> entities
               vertices -> for v <- vertices do
                             # fetch the label of the vertex
                             elem(:digraph.vertex(graph, v), 1)
                           end
             end

    :digraph.delete(graph)
    result
  end
end
