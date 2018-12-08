-module(rebar3_elixir_utils).

-export([to_binary/1, 
         get_env/1, 
         compile_app/2, 
         move_deps/3, 
         add_elixir/1, 
         create_rebar_lock_from_mix/1, 
         create_rebar_lock_from_mix/2]).

-spec to_binary(binary() | list() | integer() | atom()) -> binary().
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, latin1);
to_binary(_) -> erlang:error(badarg).

-spec get_env(rebar_state:t()) -> rebar_state:t().
get_env(State) ->
  Config = rebar_state:get(State, iex_opts, []),
  case os:getenv("MIX_ENV") of
    false ->
      case lists:keyfind(env, 1, Config) of
        {env, E} ->
          E;
        _ ->
          prod
      end;
    E ->
      list_to_atom(E)
  end.

-spec profile(atom()) -> string().
profile(Env) ->
  case Env of
    dev -> ""; 
    prod -> "env MIX_ENV=" ++ atom_to_list(Env)
  end.   

-spec get_bin_dir(rebar_state:t()) -> string().
get_bin_dir(State) ->
  Config = rebar_state:get(State, iex_opts, []),
  case lists:keyfind(bin_dir, 1, Config) of
    false -> 
      {ok, ElixirBin_} = find_executable("elixir"),
      filename:dirname(ElixirBin_);
    {bin_dir, Dir1} -> Dir1
  end.

-spec get_lib_dir(rebar_state:t()) -> string().
get_lib_dir(State) ->
  Config = rebar_state:get(State, elixir_opts, []),
  case lists:keyfind(lib_dir, 1, Config) of
    false -> 
      case rebar_utils:sh("elixir -e \"IO.puts :code.lib_dir(:elixir)\"", [return_on_error]) of
        {ok, ElixirLibs_} ->
          filename:join(re:replace(ElixirLibs_, "\\s+", "", [global,{return,list}]), "../");
        _ ->
          "/usr/local/lib/elixir/bin/../lib/elixir"
      end;
    {lib_dir, Dir2} -> Dir2
  end.

-spec compile_app(rebar_state:t(), string()) -> {ok, atom()} | error.
compile_app(State, Dir) ->
  Env = get_env(State),
  Profile = profile(Env),
  BinDir = get_bin_dir(State),
  Mix = filename:join(BinDir, "mix"),
  case ec_file:exists(filename:join(Dir, "mix.exs")) of
    true ->
      rebar_utils:sh(Profile ++ " " ++ Mix ++ " deps.get", [{cd, Dir}, {use_stdout, false}, abort_on_error]),
      rebar_utils:sh(Profile ++ " " ++ Mix ++ " compile", [{cd, Dir}, {use_stdout, false}, abort_on_error]),
      {ok, Env};
    false ->
      error
  end.

-spec move_deps(list(), string(), rebar_state:t()) -> list().
move_deps(Deps, Dir, State) ->
  BuildPath = filename:join([rebar_dir:root_dir(State), "_build/", "default/lib"]),
  lists:map(
    fun(Dep) ->
        Source = filename:join([Dir, Dep]),
        Target = filename:join([BuildPath, Dep]),              
        ec_file:copy(Source, Target, [recursive])
    end, Deps).

-spec create_rebar_lock_from_mix(string()) -> ok | {error, term()}.
create_rebar_lock_from_mix(AppDir) ->
  create_rebar_lock_from_mix(AppDir, AppDir).

-spec create_rebar_lock_from_mix(string(), string()) -> ok | {error, term()}.
create_rebar_lock_from_mix(AppDir, TargetDir) ->
  MixLocks = get_mix_lock(AppDir),
  RebarLocks = 
    lists:foldl(
      fun(AppLock, Locks) ->
          case AppLock of
            {Name, {hex, App, Version, _, _, _, _}} ->
              Locks ++ [{Name, {iex_dep, App, Version}, 0}];
            {Name, {git, URL, Hash, _}} ->
              Locks ++ [{Name, {iex_dep, URL, Hash}, 0}];
            _->
              Locks
          end
      end, [], MixLocks),
  rebar_config:write_lock_file(filename:join(TargetDir, "rebar.lock"), RebarLocks).
  

-spec add_elixir(rebar_state:t()) -> rebar_state:t().
add_elixir(State) ->
  LibDir = get_lib_dir(State),
  code:add_patha(filename:join(LibDir, "elixir/ebin")),
  code:add_patha(filename:join(LibDir, "mix/ebin")),
  code:add_patha(filename:join(LibDir, "logger/ebin")),
  State.

%%=============================
%% Private functions
%%=============================

%% Return the filepath of an executable file
find_executable(Name) ->
  case os:find_executable(Name) of
    false -> false;
    Path -> {ok, filename:nativename(Path)}
  end.

%% Get mix.lock from deps 
get_mix_lock(AppDir) ->
  Lockfile = filename:join(AppDir, "mix.lock"),
  application:ensure_all_started(elixir),
  case 'Elixir.File':read(Lockfile) of
    {ok,Info} ->
      Opts = [{file, to_binary(Lockfile)}, {warn_on_unnecessary_quotes, false}],
      {ok, Quoted} = 'Elixir.Code':string_to_quoted(Info, Opts),
      {EvalRes, _Binding} = 'Elixir.Code':eval_quoted(Quoted, Opts),
      'Elixir.Enum':to_list(EvalRes);
    {error, _} ->
      []
  end.
