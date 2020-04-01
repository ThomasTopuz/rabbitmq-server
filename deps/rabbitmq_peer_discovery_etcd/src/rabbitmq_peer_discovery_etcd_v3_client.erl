%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% Copyright (c) 2020 VMware, Inc. or its affiliates. All rights reserved.
%%
-module(rabbitmq_peer_discovery_etcd_v3_client).

%% API
-export([]).


-behaviour(gen_statem).

-export([start_link/1, start/1, stop/0]).
-export([init/1, callback_mode/0, terminate/3]).
-export([register/1, register/0, unregister/1, unregister/0, list_nodes/0, list_nodes/1]).
-export([lock/0, lock/1, lock/2, unlock/0, unlock/1, unlock/2]).
-export([recover/3, connected/3, disconnected/3]).

-import(rabbit_data_coercion, [to_binary/1]).

-compile(nowarn_unused_function).

-record(statem_data, {
    endpoints,
    connection_name,
    connection_pid,
    connection_monitor,
    key_prefix,
    cluster_name,
    node_key_lease_id,
    node_key_ttl_in_seconds,
    lock_ttl_in_seconds
}).

%%
%% API
%%

-define(ETCD_CONN_NAME, ?MODULE).
%% 60s by default matches the default heartbeat timeout.
%% We add 1s for state machine bookkeeping and
-define(DEFAULT_NODE_KEY_LEASE_TTL, 61).
-define(CALL_TIMEOUT, 15000).

start(Conf) ->
    gen_statem:start({local, ?MODULE}, ?MODULE, Conf, []).

start_link(Conf) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, Conf, []).

stop() ->
    gen_statem:stop(?MODULE).

init(Args) ->
    ok = application:ensure_started(eetcd),
    Settings = normalize_settings(Args),
    Endpoints = maps:get(endpoints, Settings),
    Actions = [{next_event, internal, start}],
    {ok, recover, #statem_data{
        endpoints = Endpoints,
        key_prefix = maps:get(etcd_prefix, Settings, <<"rabbitmq">>),
        node_key_ttl_in_seconds = maps:get(etcd_node_ttl, Settings, ?DEFAULT_NODE_KEY_LEASE_TTL),
        cluster_name = maps:get(cluster_name, Settings, <<"default">>),
        lock_ttl_in_seconds = maps:get(lock_wait_time, Settings, 30)
    }, Actions}.

callback_mode() -> [state_functions, state_enter].

terminate(Reason, State, Data) ->
    rabbit_log:debug("etcd v3 API client will terminate in state ~p, reason: ~p",
                     [State, Reason]),
    disconnect(?ETCD_CONN_NAME, Data),
    rabbit_log:debug("etcd v3 API client has disconnected"),
    rabbit_log:debug("etcd v3 API client: total number of connections to etcd is ~p", [length(eetcd_conn_sup:info())]),
    ok.

register() ->
    register(?MODULE).

register(ServerRef) ->
    gen_statem:call(ServerRef, register, ?CALL_TIMEOUT).

unregister() ->
    ?MODULE:unregister(?MODULE).

unregister(ServerRef) ->
    gen_statem:call(ServerRef, unregister, ?CALL_TIMEOUT).

list_nodes() ->
    list_nodes(?MODULE).

list_nodes(ServerRef) ->
    gen_statem:call(ServerRef, list_keys, ?CALL_TIMEOUT).

lock() ->
    lock(?MODULE, node()).

lock(Node) ->
    lock(?MODULE, Node).

lock(ServerRef, Node) ->
    gen_statem:call(ServerRef, {lock, Node}, ?CALL_TIMEOUT).

unlock() ->
    unlock(?MODULE, node()).

unlock(Node) ->
    unlock(?MODULE, Node).

unlock(ServerRef, Node) ->
    gen_statem:call(ServerRef, {unlock, Node}, ?CALL_TIMEOUT).

%%
%% States
%%

recover(enter, _PrevState, #statem_data{endpoints = Endpoints}) ->
    rabbit_log:debug("etcd v3 API client has entered recovery state, endpoints: ~s",
                     [string:join(Endpoints, ",")]),
    keep_state_and_data;
recover(internal, start, Data = #statem_data{endpoints = Endpoints, connection_monitor = Ref}) ->
    rabbit_log:debug("etcd v3 API client will attempt to connect, endpoints: ~s",
                     [string:join(Endpoints, ",")]),
    maybe_demonitor(Ref),
    Transport = tcp,
    TransportOpts = [],
    ConnName = ?ETCD_CONN_NAME,
    case connect(ConnName, Endpoints, Transport, TransportOpts) of
        {ok, Pid} ->
            rabbit_log:debug("etcd v3 API client connection: ~p", [Pid]),
            rabbit_log:debug("etcd v3 API client: total number of connections to etcd is ~p", [length(eetcd_conn_sup:info())]),
            {next_state, connected, Data#statem_data{
                connection_name = ConnName,
                connection_pid = Pid,
                connection_monitor = monitor(process, Pid)
            }};
        {error, Errors} ->
            [rabbit_log:error("etcd peer discovery: failed to connect to endpoint ~p: ~p", [Endpoint, Err]) || {Endpoint, Err} <- Errors],
            ensure_disconnected(?ETCD_CONN_NAME, Data),
            Actions = [{state_timeout, reconnection_interval(), recover}],
            {keep_state, reset_statem_data(Data), Actions}
    end;
recover(state_timeout, _PrevState, Data) ->
    rabbit_log:debug("etcd peer discovery: connection entered a reconnection delay state"),
    ensure_disconnected(?ETCD_CONN_NAME, Data),
    {next_state, recover, reset_statem_data(Data)}.


connected(enter, _PrevState, Data) ->
    rabbit_log:info("etcd peer discovery: successfully connected to etcd"),

    {keep_state, acquire_node_key_lease_grant(Data)};
connected(info, {'DOWN', ConnRef, process, ConnPid, Reason}, Data = #statem_data{
                                                               connection_pid = ConnPid,
                                                               connection_monitor = ConnRef
                                                             }) ->
    rabbit_log:debug("etcd peer discovery: connection to etcd ~p is down: ~p", [ConnPid, Reason]),
    maybe_demonitor(ConnRef),
    {next_state, recover, reset_statem_data(Data)};
connected({call, From}, {lock, _Node}, Data = #statem_data{connection_name = Conn, lock_ttl_in_seconds = TTL}) ->
    case eetcd_lease:grant(eetcd_kv:new(Conn), TTL) of
        {ok, #{'ID' := LeaseID}} ->
            Key = lock_key_base(Data),
            rabbit_log:debug("etcd peer discovery: granted a lease ~p for registration lock ~s with TTL = ~p", [LeaseID, Key, TTL]),
            case eetcd_lock:lock(lock_context(Conn, Data), Key, LeaseID) of
                {ok, #{key := GeneratedKey}} ->
                    rabbit_log:debug("etcd peer discovery: successfully acquired a lock, lock owner key: ~s", [GeneratedKey]),
                    reply_and_retain_state(From, {ok, GeneratedKey});
                {error, _} = Error ->
                    rabbit_log:debug("etcd peer discovery: failed to acquire a lock using key ~s: ~p", [Key, Error]),
                    reply_and_retain_state(From, Error)
            end;
        {error, _} = Error ->
            rabbit_log:debug("etcd peer discovery: failed to get a lease for registration lock: ~p", [Error]),
            reply_and_retain_state(From, Error)
    end;
connected({call, From}, {unlock, GeneratedKey}, Data = #statem_data{connection_name = Conn}) ->
    Ctx = unlock_context(Conn, Data),
    case eetcd_lock:unlock(Ctx, GeneratedKey) of
        {ok, _} ->
            reply_and_retain_state(From, ok);
        {error, _} = Error ->
            reply_and_retain_state(From, Error)
    end;
connected({call, From}, register, Data = #statem_data{connection_name = Conn}) ->
    Ctx = registration_context(Conn, Data),
    Key = node_key(Data),
    eetcd_kv:put(Ctx, Key, registration_value(Data)),
    rabbit_log:debug("etcd peer discovery: put key ~p, done with registration", [Key]),
    gen_statem:reply(From, ok),
    keep_state_and_data;
connected({call, From}, unregister, Data = #statem_data{connection_name = Conn}) ->
    unregister(Conn, Data),
    gen_statem:reply(From, ok),
    {keep_state, Data#statem_data{
        node_key_lease_id = undefined
    }};
connected({call, From}, list_keys, #statem_data{connection_name = Conn, cluster_name = ClusterName, key_prefix = KP}) ->
    Prefix = node_key_base(KP, ClusterName),
    C1 = eetcd_kv:new(Conn),
    C2 = eetcd_kv:with_prefix(eetcd_kv:with_key(C1, Prefix)),
    rabbit_log:debug("etcd peer discovery: will use prefix ~s to query for node keys", [Prefix]),
    {ok, #{kvs := Result}} = eetcd_kv:get(C2),
    rabbit_log:debug("etcd peer discovery returned keys: ~p", [Result]),
    Values = [maps:get(value, M) || M <- Result],
    case Values of
        Xs when is_list(Xs) ->
            rabbit_log:debug("etcd peer discovery: listing node keys returned ~b results", [length(Xs)]),
            ParsedNodes = lists:map(fun extract_node/1, Xs),
            {Successes, Failures} = lists:partition(fun filter_node/1, ParsedNodes),
            JoinedString = lists:join(",", [rabbit_data_coercion:to_list(Node) || Node <- lists:usort(Successes)]),
            rabbit_log:error("etcd peer discovery: successfully extracted nodes: ~s", [JoinedString]),
            lists:foreach(fun(Val) ->
                rabbit_log:error("etcd peer discovery: failed to extract node name from etcd value ~p", [Val])
            end, Failures),
            gen_statem:reply(From, lists:usort(Successes)),
            keep_state_and_data;
        Other ->
            rabbit_log:debug("etcd peer discovery: listing node keys returned ~p", [Other]),
            gen_statem:reply(From, []),
            keep_state_and_data
    end.

disconnected(enter, _PrevState, _Data) ->
    rabbit_log:info("etcd peer discovery: successfully disconnected from etcd"),
    keep_state_and_data.


%%
%% Implementation
%%

acquire_node_key_lease_grant(Data = #statem_data{connection_name = Name, node_key_ttl_in_seconds = TTL}) ->
    %% acquire a lease for TTL
    {ok, #{'ID' := LeaseID}} = eetcd_lease:grant(Name, TTL),
    rabbit_log:debug("etcd peer discovery: acquired a lease ~p for node key ~s with TTL = ~p", [LeaseID, node_key(Data), TTL]),
    Data#statem_data{
        node_key_lease_id = LeaseID
    }.

registration_context(ConnName, #statem_data{node_key_lease_id = LeaseID}) ->
    Ctx1 = eetcd_kv:new(ConnName),
    eetcd_kv:with_lease(Ctx1, LeaseID).

unregistration_context(ConnName, _Data) ->
    eetcd_kv:new(ConnName).

lock_context(ConnName, #statem_data{lock_ttl_in_seconds = LeaseTTL}) ->
    %% LeaseTT is in seconds, eetcd_lock:with_timeout/2 expects milliseconds
    eetcd_lock:with_timeout(eetcd_lock:new(ConnName), LeaseTTL * 1000).

unlock_context(ConnName, #statem_data{lock_ttl_in_seconds = Timeout}) ->
    %% caps the timeout here using the lock TTL value, it makes more
    %% sense than picking an arbitrary number. MK.
    eetcd_lock:with_timeout(eetcd_lock:new(ConnName), Timeout).

node_key_base(Prefix, ClusterName) ->
    rabbit_misc:format("/rabbitmq/discovery/~s/clusters/~s/nodes", [Prefix, ClusterName]).

node_key(#statem_data{key_prefix = Prefix, cluster_name = ClusterName}) ->
    to_binary(rabbit_misc:format("~s/~s", [node_key_base(Prefix, ClusterName), node()])).

lock_key_base(#statem_data{key_prefix = Prefix, cluster_name = ClusterName}) ->
    Key = rabbit_misc:format("/rabbitmq/locks/~s/clusters/~s/registration",
                             [Prefix, ClusterName]),
    to_binary(Key).

%% This value is not used and merely
%% provides additional context to the operator.
registration_value(#statem_data{node_key_lease_id = LeaseID, node_key_ttl_in_seconds = TTL}) ->
    to_binary(rabbit_json:encode(#{
        <<"node">>     => to_binary(node()),
        <<"lease_id">> => LeaseID,
        <<"ttl">>      => TTL
    })).

-spec extract_node(binary()) -> atom() | {error, any()}.

extract_node(Payload) ->
    case rabbit_json:decode(Payload) of
        {error, Error} -> {error, Error};
        Map ->
            case maps:get(<<"node">>, Map, undefined) of
                undefined -> undefined;
                Node      -> rabbit_data_coercion:to_atom(Node)
            end
    end.

filter_node(undefined)  -> false;
filter_node({error, _}) -> false;
filter_node(_Other)     -> true.


error_is_already_started({_Endpoint, already_started}) ->
    true;
error_is_already_started({_Endpoint, _}) ->
    false.

connect(Name, Endpoints, Transport, TransportOpts) ->
    case eetcd_conn:lookup(Name) of
        {ok, Pid} when is_pid(Pid) ->
            {ok, Pid};
        {error, eetcd_conn_unavailable} ->
            do_connect(Name, Endpoints, Transport, TransportOpts)
    end.

do_connect(Name, Endpoints, Transport, TransportOpts) ->
    case eetcd:open(Name, Endpoints, [{mode, random}], Transport, TransportOpts) of
        {ok, Pid} -> {ok, Pid};
        {error, Errors} ->
            rabbit_log:debug("etcd peer discovery: connection errors: ~p",
                             [Errors]),
            rabbit_log:debug("etcd peer discovery: are all connection errors benign?: ~p",
                             [lists:all(fun error_is_already_started/1, Errors)]),
            %% If all errors are already_started we can ignore them.
            %% eetcd registers connections under a name
            case lists:all(fun error_is_already_started/1, Errors) of
                true ->
                    eetcd_conn:lookup(Name);
                false ->
                    {error, Errors}
            end
    end.

disconnect(ConnName, #statem_data{connection_monitor = Ref}) ->
    maybe_demonitor(Ref),
    do_disconnect(ConnName).

unregister(Conn, Data = #statem_data{node_key_lease_id = LeaseID}) ->
    Ctx = unregistration_context(Conn, Data),
    Key = node_key(Data),
    eetcd_kv:delete(Ctx, Key),
    rabbit_log:debug("etcd peer discovery: deleted key ~s, done with unregistration", [Key]),
    eetcd_lease:revoke(Ctx, LeaseID),
    rabbit_log:debug("etcd peer discovery: revoked a lease ~p for node key ~s", [LeaseID, Key]),
    ok.

reply_and_retain_state(From, Value) ->
    gen_statem:reply(From, Value),
    keep_state_and_data.

maybe_demonitor(undefined) ->
    true;
maybe_demonitor(Ref) when is_reference(Ref) ->
    erlang:demonitor(Ref).

reset_statem_data(Data0 = #statem_data{endpoints = Es, connection_monitor = Ref}) when Es =/= undefined ->
    maybe_demonitor(Ref),
    Data0#statem_data{
        connection_pid = undefined,
        connection_monitor = undefined
    }.

ensure_disconnected(Name, #statem_data{connection_monitor = Ref}) ->
    maybe_demonitor(Ref),
    do_disconnect(Name).

do_disconnect(Name) ->
    try
        eetcd:close(Name)
    catch _:_ ->
        ok
    end.

reconnection_interval() ->
    3000.


normalize_settings(Map) when is_map(Map) ->
    Endpoints = maps:get(endpoints, Map, []),
    LegacyEndpoints = case maps:get(etcd_host, Map, undefined) of
        undefined -> [];
        Hostname ->
            Port = maps:get(etcd_port, Map, 2379),
            [rabbit_misc:format("~s:~p", [Hostname, Port])]
    end,

    AllEndpoints = Endpoints ++ LegacyEndpoints,
    maps:merge(maps:without([etcd_prefix, etcd_node_ttl, lock_wait_time], Map),
               #{endpoints => AllEndpoints}).
