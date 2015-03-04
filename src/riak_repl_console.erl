%% Riak EnterpriseDS
%% Copyright 2007-2015 Basho Technologies, Inc. All Rights Reserved.
-module(riak_repl_console).
-include("riak_repl.hrl").
-behaviour(clique_handler).

%% Clique behavior
-export([register_cli/0]).

%% Main entry-point for script
-export([command/1]).

%% Utility functions for script integration
-export([script_name/0,
         register_command/4,
         register_usage/2]).

%% Stats functions
-export([client_stats_rpc/0,
         server_stats_rpc/0]).
-export([extract_rt_fs_send_recv_kbps/1]).

-export([rt_remotes_status/0,
         fs_remotes_status/0]).

-export([get_config/0,
         leader_stats/0,
         client_stats/0,
         server_stats/0,
         coordinator_stats/0,
         coordinator_srv_stats/0]).

%% Modes functions
-export([modes/1, set_modes/1, get_modes/0]).

%% Ring utilities
-export([get_ring/0, maybe_set_ring/2]).


-spec register_cli() -> ok.
register_cli() ->
    riak_repl_console13:register_cli().

-spec script_name() -> string().
script_name() ->
    case get(script_name) of
        undefined -> "riak-repl";
        Script    -> Script
    end.

-spec register_command([string()], list(), list(), fun()) -> ok.
register_command(Cmd, Keys, Flags, Fun) ->
    clique:register_command(["riak-repl"|Cmd], Keys, Flags, Fun).

-spec register_usage([string()], iolist() | fun(() -> iolist())) -> ok.
register_usage(Cmd, Usage) ->
    UsageFun = fun() ->
                       UsageStr = if is_function(Usage) -> Usage();
                                     true -> Usage
                                  end,
                       ScriptName = script_name(),
                       erase(script_name),
                       [ScriptName, " ", UsageStr]
               end,
    clique:register_usage(["riak-repl"|Cmd], UsageFun).

%% @doc Entry-point for all riak-repl commands.
-spec command([string()]) -> ok | error.
command([Script|Args]) ->
    %% We stash the script name (which may be a partial or absolute
    %% path) in the process dictionary so usage output can grab it
    %% later.
    put(script_name, Script),
    %% We don't really want to touch legacy commands, so try to
    %% dispatch them first.
    case riak_repl_console12:dispatch(Args) of
        %% If there's no matching legacy command (or usage should be
        %% printed), try to "upgrade" the arguments to clique-style,
        %% then invoke clique.
        nomatch ->
            NewCmd = riak_repl_console13:upgrade(Args),
            clique:run(["riak-repl"|NewCmd]);
        OkOrError ->
            OkOrError
    end.

set_modes(Modes) ->
    Ring = get_ring(),
    NewRing = riak_repl_ring:set_modes(Ring, Modes),
    ok = maybe_set_ring(Ring, NewRing).

get_modes() ->
    Ring = get_ring(),
    riak_repl_ring:get_modes(Ring).


status([]) ->
    status2(true);
status(quiet) ->
    status2(false).

status2(Verbose) ->
    Config = get_config(),
    Stats1 = riak_repl_stats:get_stats(),
    RTRemotesStatus = rt_remotes_status(),
    FSRemotesStatus = fs_remotes_status(),
    PGRemotesStatus = pg_remotes_status(),
    LeaderStats = leader_stats(),
    ClientStats = client_stats(),
    ServerStats = server_stats(),
    CoordStats = coordinator_stats(),
    CoordSrvStats = coordinator_srv_stats(),
    CMgrStats = cluster_mgr_stats(),
    RTQStats = rtq_stats(),
    PGStats = riak_repl2_pg:status(),

    Most =
        RTRemotesStatus++FSRemotesStatus++PGRemotesStatus++Config++
        Stats1++LeaderStats++ClientStats++ServerStats++
        CoordStats++CoordSrvStats++CMgrStats++RTQStats++PGStats,
    SendRecvKbps = extract_rt_fs_send_recv_kbps(Most),
    All = Most ++ SendRecvKbps,
    if Verbose ->
            format_counter_stats(All);
       true ->
            All
    end.

pg_remotes_status() ->
    Ring = get_ring(),
    Enabled = string:join(riak_repl_ring:pg_enabled(Ring),", "),
    [{proxy_get_enabled, Enabled}].

rt_remotes_status() ->
    Ring = get_ring(),
    Enabled = string:join(riak_repl_ring:rt_enabled(Ring),", "),
    Started = string:join(riak_repl_ring:rt_started(Ring),", "),
    [{realtime_enabled, Enabled},
     {realtime_started, Started}].

fs_remotes_status() ->
    Ring = get_ring(),
    Sinks = riak_repl_ring:fs_enabled(Ring),
    RunningSinks = [Sink || Sink <- Sinks, cluster_fs_running(Sink)],
    [{fullsync_enabled, string:join(Sinks, ", ")},
     {fullsync_running, string:join(RunningSinks, ", ")}].

cluster_fs_running(Sink) ->
    ClusterCoord = riak_repl2_fscoordinator_sup:coord_for_cluster(Sink),
    riak_repl2_fscoordinator:is_running(ClusterCoord).

modes([]) ->
    CurrentModes = get_modes(),
    io:format("Current replication modes: ~p~n",[CurrentModes]),
    ok;
modes(NewModes) ->
    ?LOG_USER_CMD("Set replication mode(s) to ~p",[NewModes]),
    Modes = [ list_to_atom(Mode) || Mode <- NewModes],
    set_modes(Modes),
    modes([]).

%% helper functions

extract_rt_fs_send_recv_kbps(Most) ->
    RTSendKbps = sum_rt_send_kbps(Most),
    RTRecvKbps = sum_rt_recv_kbps(Most),
    FSSendKbps = sum_fs_send_kbps(Most),
    FSRecvKbps = sum_fs_recv_kbps(Most),
    [{realtime_send_kbps, RTSendKbps}, {realtime_recv_kbps, RTRecvKbps},
     {fullsync_send_kbps, FSSendKbps}, {fullsync_recv_kbps, FSRecvKbps}].


format_counter_stats([]) -> ok;
format_counter_stats([{K,V}|T]) when is_list(K) ->
    io:format("~s: ~p~n", [K,V]),
    format_counter_stats(T);
%%format_counter_stats([{K,V}|T]) when K == fullsync_coordinator ->
%%    io:format("V = ~p",[V]),
%%    case V of
%%        [] -> io:format("~s: {}~n",[K]);
%%        Val -> io:format("~s: ~s",[K,Val])
%%    end,
%%    format_counter_stats(T);
format_counter_stats([{K,V}|T]) when K == client_rx_kbps;
                                     K == client_tx_kbps;
                                     K == server_rx_kbps;
                                     K == server_tx_kbps ->
    io:format("~s: ~w~n", [K,V]),
    format_counter_stats(T);
format_counter_stats([{K,V}|T]) ->
    io:format("~p: ~p~n", [K,V]),
    format_counter_stats(T);
format_counter_stats([{_K,_IPAddr,_V}|T]) ->
    %% Don't include per-IP stats in this output
    %% io:format("~p(~p): ~p~n", [K,IPAddr,V]),
    format_counter_stats(T).

maybe_set_ring(_R, _R) -> ok;
maybe_set_ring(_R1, R2) ->
    RC = riak_repl_ring:get_repl_config(R2),
    F = fun(InRing, ReplConfig) ->
                {new_ring, riak_repl_ring:set_repl_config(InRing, ReplConfig)}
        end,
    RC = riak_repl_ring:get_repl_config(R2),
    {ok, _NewRing} = riak_core_ring_manager:ring_trans(F, RC),
    ok.

get_ring() ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    riak_repl_ring:ensure_config(Ring).

get_config() ->
    {ok, R} = riak_core_ring_manager:get_my_ring(),
    case riak_repl_ring:get_repl_config(R) of
        undefined ->
            [];
        Repl ->
            case dict:find(sites, Repl) of
                error ->
                    [];
                {ok, Sites} ->
                    lists:flatten([format_site(S) || S <- Sites])
            end ++
                case dict:find(listeners, Repl) of
                    error ->
                        [];
                    {ok, Listeners} ->
                        lists:flatten([format_listener(L) || L <- Listeners])
                end ++
                case dict:find(natlisteners, Repl) of
                    error ->
                        [];
                    {ok, NatListeners} ->
                        lists:flatten([format_nat_listener(L) || L <- NatListeners])
                end
    end.

format_site(S) ->
    [{S#repl_site.name ++ "_ips", format_ips(S#repl_site.addrs)}].

format_ips(IPs) ->
    string:join([format_ip(IP) || IP <- IPs], ", ").

format_ip({Addr,Port}) ->
    lists:flatten(io_lib:format("~s:~p", [Addr, Port])).

format_listener(L) ->
    [{"listener_" ++ atom_to_list(L#repl_listener.nodename),
      format_ip(L#repl_listener.listen_addr)}].

format_nat_listener(L) ->
    [{"natlistener_" ++ atom_to_list(L#nat_listener.nodename),
      format_ip(L#nat_listener.listen_addr) ++ "->" ++
          format_ip(L#nat_listener.nat_addr)}].

leader_stats() ->
    case erlang:whereis(riak_repl_leader_gs) of
        Pid when is_pid(Pid) ->
            LeaderNode = riak_repl_leader:leader_node(),
            LocalStats =
                try
                    LocalProcInfo = erlang:process_info(whereis(riak_repl_leader_gs),
                                                        [message_queue_len, heap_size]),
                    [{"local_leader_" ++  atom_to_list(K), V} || {K,V} <- LocalProcInfo]
                catch _:_ ->
                        []
                end,
            RemoteStats =
                try
                    LeaderPid = rpc:call(LeaderNode, erlang, whereis,
                                         [riak_repl_leader_gs]),
                    LeaderStats = rpc:call(LeaderNode, erlang, process_info,
                                           [LeaderPid, [message_queue_len,
                                                        total_heap_size,
                                                        heap_size,
                                                        stack_size,
                                                        reductions,
                                                        garbage_collection]]),
                    [{"leader_" ++  atom_to_list(K), V} || {K,V} <- LeaderStats]
                catch
                    _:_ ->
                        []
                end,
            [{leader, LeaderNode}] ++ RemoteStats ++ LocalStats;
        _ -> []
    end.

client_stats() ->
    case erlang:whereis(riak_repl_leader_gs) of
        Pid when is_pid(Pid) ->
            %% NOTE: rpc:multicall to all clients removed
            riak_repl_console:client_stats_rpc();
        _ -> []
    end.

client_stats_rpc() ->
    RT2 = [rt2_sink_stats(P) || P <- riak_repl2_rt:get_sink_pids()] ++
        [fs2_sink_stats(P) || P <- riak_repl2_fssink_sup:started()],
    Pids = [P || {_,P,_,_} <- supervisor:which_children(riak_repl_client_sup), P /= undefined],
    [{client_stats, [client_stats(P) || P <- Pids]}, {sinks, RT2}].

server_stats() ->
    case erlang:whereis(riak_repl_leader_gs) of
        Pid when is_pid(Pid) ->
            RT2 = [rt2_source_stats(P) || {_R,P} <-
                                              riak_repl2_rtsource_conn_sup:enabled()],
            LeaderNode = riak_repl_leader:leader_node(),
            case LeaderNode of
                undefined ->
                    [{sources, RT2}];
                _ ->
                    [{server_stats, rpc:call(LeaderNode, ?MODULE, server_stats_rpc,
                                             [])},
                     {sources, RT2}]
            end;
        _ -> []
    end.

rtq_stats() ->
    case erlang:whereis(riak_repl2_rtq) of
        Pid when is_pid(Pid) ->
            [{realtime_queue_stats, riak_repl2_rtq:status()}];
        _ -> []
    end.

cluster_mgr_stats() ->
    case erlang:whereis(riak_repl_leader_gs) of
        Pid when is_pid(Pid) ->
            ConnectedClusters = case riak_core_cluster_mgr:get_known_clusters() of
                {ok, Clusters} ->
                    [erlang:list_to_binary(Cluster) || Cluster <-
                                                       Clusters];
                Error -> Error
            end,
            [{cluster_name,
              erlang:list_to_binary(riak_core_connection:symbolic_clustername())},
             {cluster_leader, riak_core_cluster_mgr:get_leader()},
             {connected_clusters, ConnectedClusters}];
        _ -> []
    end.


server_stats_rpc() ->
    [server_stats(P) ||
        P <- riak_repl_listener_sup:server_pids()].

%%socket_stats(Pid) ->
%%    Timeout = app_helper:get_env(riak_repl, status_timeout, 5000),
%%    State = try
%%                riak_repl_tcp_mon:status(Pid, Timeout)
%%            catch
%%                _:_ ->
%%                    too_busy
%%            end,
%%    {Pid, erlang:process_info(Pid, message_queue_len), State}.

client_stats(Pid) ->
    Timeout = app_helper:get_env(riak_repl, status_timeout, 5000),
    State = try
                riak_repl_tcp_client:status(Pid, Timeout)
            catch
                _:_ ->
                    too_busy
            end,
    {Pid, erlang:process_info(Pid, message_queue_len), State}.

server_stats(Pid) ->
    Timeout = app_helper:get_env(riak_repl, status_timeout, 5000),
    State = try
                riak_repl_tcp_server:status(Pid, Timeout)
            catch
                _:_ ->
                    too_busy
            end,
    {Pid, erlang:process_info(Pid, message_queue_len), State}.

coordinator_stats() ->
    case erlang:whereis(riak_repl_leader_gs) of
        Pid when is_pid(Pid) ->
            [{fullsync_coordinator, riak_repl2_fscoordinator:status()}];
        _ -> []
    end.

coordinator_srv_stats() ->
    case erlang:whereis(riak_repl_leader_gs) of
        Pid when is_pid(Pid) ->
            [{fullsync_coordinator_srv, riak_repl2_fscoordinator_serv:status()}];
        _ -> []
    end.

rt2_source_stats(Pid) ->
    Timeout = app_helper:get_env(riak_repl, status_timeout, 5000),
    State = try
                riak_repl2_rtsource_conn:status(Pid, Timeout)
            catch
                _:_ ->
                    too_busy
            end,
    FormattedPid = riak_repl_util:safe_pid_to_list(Pid),
    {source_stats, [{pid,FormattedPid}, erlang:process_info(Pid, message_queue_len),
                    {rt_source_connected_to, State}]}.

rt2_sink_stats(Pid) ->
    Timeout = app_helper:get_env(riak_repl, status_timeout, 5000),
    State = try
                riak_repl2_rtsink_conn:status(Pid, Timeout)
            catch
                _:_ ->
                    too_busy
            end,
    %%{Pid, erlang:process_info(Pid, message_queue_len), State}.
    FormattedPid = riak_repl_util:safe_pid_to_list(Pid),
    {sink_stats, [{pid,FormattedPid}, erlang:process_info(Pid, message_queue_len),
                  {rt_sink_connected_to, State}]}.

fs2_sink_stats(Pid) ->
    Timeout = app_helper:get_env(riak_repl, status_timeout, 5000),
    State = try
                %% even though it's named legacy_status, it's BNW code
                riak_repl2_fssink:legacy_status(Pid, Timeout)
            catch
                _:_ ->
                    too_busy
            end,
    %% {Pid, erlang:process_info(Pid, message_queue_len), State}.
    {sink_stats, [{pid,riak_repl_util:safe_pid_to_list(Pid)},
                  erlang:process_info(Pid, message_queue_len),
                  {fs_connected_to, State}]}.

sum_rt_send_kbps(Stats) ->
    sum_rt_kbps(Stats, send_kbps).

sum_rt_recv_kbps(Stats) ->
    sum_rt_kbps(Stats, recv_kbps).

sum_rt_kbps(Stats, KbpsDirection) ->
    Sinks = proplists:get_value(sinks, Stats, []),
    Sources = proplists:get_value(sources, Stats, []),
    Kbpss = lists:foldl(fun({StatKind, SinkProps}, Acc) ->
                                Path1 = case StatKind of
                                            sink_stats -> rt_sink_connected_to;
                                            source_stats -> rt_source_connected_to;
                                            _Else -> not_found
                                        end,
                                KbpsStr = proplists_get([Path1, socket, KbpsDirection], SinkProps, "[]"),
                                get_first_kbsp(KbpsStr) + Acc
                        end, 0, Sinks ++ Sources),
    Kbpss.

sum_fs_send_kbps(Stats) ->
    sum_fs_kbps(Stats, send_kbps).

sum_fs_recv_kbps(Stats) ->
    sum_fs_kbps(Stats, recv_kbps).

sum_fs_kbps(Stats, Direction) ->
    Coordinators = proplists:get_value(fullsync_coordinator, Stats),
    CoordFoldFun = fun({_SinkName, FSCoordStats}, Acc) ->
                           CoordKbpsStr = proplists_get([socket, Direction], FSCoordStats, "[]"),
                           CoordKbps = get_first_kbsp(CoordKbpsStr),
                           CoordSourceKpbs = sum_fs_source_kbps(FSCoordStats, Direction),
                           SinkKbps = sum_fs_sink_kbps(Stats, Direction),
                           Acc + CoordKbps + CoordSourceKpbs + SinkKbps
                   end,
    CoordSrvs = proplists:get_value(fullsync_coordinator_srv, Stats),
    CoordSrvsFoldFun = fun({_IPPort, SrvStats}, Acc) ->
                               KbpsStr = proplists_get([socket, Direction], SrvStats, "[]"),
                               Kbps = get_first_kbsp(KbpsStr),
                               Kbps + Acc
                       end,
    lists:foldl(CoordFoldFun, 0, Coordinators) + lists:foldl(CoordSrvsFoldFun, 0, CoordSrvs).

sum_fs_source_kbps(CoordStats, Direction) ->
    Running = proplists:get_value(running_stats, CoordStats, []),
    FoldFun = fun({_Pid, Stats}, Acc) ->
                      KbpsStr = proplists_get([socket, Direction], Stats, "[]"),
                      Kbps = get_first_kbsp(KbpsStr),
                      Acc + Kbps
              end,
    lists:foldl(FoldFun, 0, Running).

sum_fs_sink_kbps(Stats, Direction) ->
    Sinks = proplists:get_value(sinks, Stats, []),
    FoldFun = fun({sink_stats, SinkStats}, Acc) ->
                      case proplists_get([fs_connected_to, socket, Direction], SinkStats) of
                          undefined ->
                              Acc;
                          KbpsStr ->
                              Kbps = get_first_kbsp(KbpsStr),
                              Acc + Kbps
                      end
              end,
    lists:foldl(FoldFun, 0, Sinks).

proplists_get(Path, Props) ->
    proplists_get(Path, Props, undefined).

proplists_get([], undefined, Default) ->
    Default;
proplists_get([], Value, _Default) ->
    Value;
proplists_get([Key], Props, Default) when is_list(Props) ->
    Value = proplists:get_value(Key, Props),
    proplists_get([], Value, Default);
proplists_get([Key | Path], Props, Default) when is_list(Props) ->
    case proplists:get_value(Key, Props) of
        undefined ->
            Default;
        too_busy ->
            lager:debug("Something was too busy to give stats"),
            Default;
        AList when is_list(AList) ->
            proplists_get(Path, AList, Default);
        Wut ->
            lager:warning("~p Not a list when getting stepwise key ~p: ~p", [Wut, [Key | Path], Props]),
            Default
    end.

get_first_kbsp(Str) ->
    case simple_parse(Str ++ ".") of
        [] -> 0;
        [V | _] -> V
    end.

simple_parse(Str) ->
    {ok, Tokens, _EoL} = erl_scan:string(Str),
    {ok, AbsForm} = erl_parse:parse_exprs(Tokens),
    {value, Value, _Bs} = erl_eval:exprs(AbsForm, erl_eval:new_bindings()),
    Value.
