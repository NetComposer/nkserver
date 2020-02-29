%% -------------------------------------------------------------------
%%
%% Copyright (c) 2020 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(nkserver).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_link/3, get_sup_spec/3, stop/1, update/2, replace/2]).
-export([set_active/2, get_local/0, get_local/1, stop_all_local/0]).
-export([get_status/0]).
-export([get_instances/0, get_instances/1, get_instances/2]).
-export([get_random_instance/1, get_random_instance/2]).
-export([get_cached_config/3, get/2, get/3, put/3, put_new/3, del/2]).
-export([get_config/1, get_plugins/1, get_uuid/1, get_service_workers/1]).
-export_type([id/0, class/0, spec/0, service/0, status/0]).


-include("nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: module().

-type class() :: atom().

-type config() :: map().

% If 'use_module' is used, id is ignored as a callback module,
% a new one is compiled from scratch based on 'use_module'
-type spec() ::
    #{
        uuid => binary(),
        plugins => binary(),
        vsn => binary(),
        master_min_nodes => pos_integer(),
        use_module => module(),
        term() => term()
    }.


-type service() ::
    #{
        id => module(),
        class => class(),
        vsn => binary(),
        uuid => binary(),
        plugins => [atom()],
        expanded_plugins => [atom()],         % Expanded, bottom to top
        use_module => module(),
        master_min_nodes => pos_integer(),
        timestamp => nklib_date:epoch(msecs),
        hash => integer(),
        config => config()
    }.


-type status() :: starting | running | updating | stopping | stopped | failing.

-type service_status() ::
    #{
        id => nkserver:id(),
        class => nkserver:class(),
        vsn => binary(),
        hash => integer(),
        pid => pid(),
        status => status(),
        last_status_time => nklib_date:epoch(msecs),
        error => term(),
        last_error_time => nklib_date:epoch(msecs)
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc
-spec start_link(class(), id(), spec()) ->
    {ok, pid()} | {error, term()}.

start_link(PkgClass, SrvId, Spec) when is_atom(PkgClass), is_atom(SrvId), is_map(Spec) ->
    nkserver_srv_sup:start_link(PkgClass, SrvId, Spec).


%% @doc
-spec get_sup_spec(class(), id(), spec()) ->
    {ok, pid()} | {error, term()}.

get_sup_spec(PkgClass, SrvId, Spec) when is_atom(PkgClass), is_atom(SrvId), is_map(Spec) ->
    #{
        id => {nkserver, SrvId},
        start => {?MODULE, start_link, [PkgClass, SrvId, Spec]},
        restart => permanent,
        shutdown => 15000,
        type => supervisor
    }.


%% @private
stop(SrvId) ->
    nkserver_srv_sup:stop(SrvId).


%% @doc Updates a service configuration in local node
-spec update(id(), spec()) ->
    ok | {error, term()}.

update(SrvId, Spec) ->
    OldConfig = nkserver:get_config(SrvId),
    Spec2 = maps:merge(OldConfig, Spec),
    replace(SrvId, Spec2).


%% @doc Updates a service configuration in local node
-spec replace(id(), spec()) ->
    ok | {error, term()}.

replace(SrvId, Spec) ->
    nkserver_srv:replace(SrvId, Spec).


%% @doc Sets a service active or not in local node
-spec set_active(id(), boolean()) ->
    ok | {error, term()}.

set_active(SrvId, Bool) when is_boolean(Bool) ->
    nkserver_srv:set_active(SrvId, {nkserver_set_active, Bool}).


%% @doc Gets all started services in current node
-spec get_local() ->
    [{id(), nkserver:class(), integer(), pid()}].

get_local() ->
    nkserver_srv:get_all_local().


%% @doc Gets all started services
-spec get_local(nkserver:class()) ->
    [{id(), nkserver:class(), pid()}].

get_local(Class) when is_atom(Class) ->
    nkserver_srv:get_all_local(Class).


%% @doc Stops all started services
-spec stop_all_local() ->
    ok.

stop_all_local() ->
    SrvIds = [SrvId || {SrvId, _Class, _Hash, _Pid} <- get_local()],
    lists:foreach(fun(SrvId) -> nkserver:stop(SrvId) end, SrvIds).



%% @doc Gets all status for all instances in all nodes
-spec get_status() -> [service_status()].

get_status() ->
    lists:foldl(
        fun(Pid, Acc) ->
            case catch nkserver_srv:get_status(Pid) of
                {ok, Status} -> [Status|Acc];
                _ -> Acc
            end
        end,
        [],
        get_instances()).


%% @doc Gets all cluster instances for all services, in any state
-spec get_instances() ->
    [pid()].

get_instances() ->
    nkserver_srv:get_instances().


%% @doc Gets all cluster instances for a service, only in running state
-spec get_instances(nkserver:id()) ->
    [pid()].

get_instances(SrvId) ->
    nkserver_srv:get_instances(SrvId).


%% @doc Gets all cluster instances for a service, only in running state
-spec get_instances(nkserver:id(), binary()) ->
    [pid()].

get_instances(SrvId, Vsn) ->
    nkserver_srv:get_instances(SrvId, Vsn).


%% @doc Gets a random instance in the cluster
-spec get_random_instance(nkserver:id()) ->
    pid()|undefined.

get_random_instance(SrvId) ->
    Pids = get_instances(SrvId),
    nklib_util:get_randomized(Pids).


%% @doc Gets a random instance in the cluster
-spec get_random_instance(nkserver:id(), binary) ->
    pid()|undefined.

get_random_instance(SrvId, Vsn) ->
    Pids = get_instances(SrvId, Vsn),
    nklib_util:get_randomized(Pids).


%% @doc Get a plugin configuration
get_cached_config(SrvId, PluginId, Key) ->
    ?CALL_SRV(SrvId, config_cache, [PluginId, Key]).


%% @doc Gets a value from service's store
-spec get(id(), term()) ->
    term().

get(SrvId, Key) ->
    get(SrvId, Key, undefined).


%% @doc Gets a value from service's store
-spec get(id(), term(), term()) ->
    term().

get(SrvId, Key, Default) ->
    case ets:lookup(SrvId, Key) of
        [{_, Value}] -> Value;
        [] -> Default
    end.


%% @doc Inserts a value in service's store
-spec put(id(), term(), term()) ->
    ok.

put(SrvId, Key, Value) ->
    true = ets:insert(SrvId, {Key, Value}),
    ok.


%% @doc Inserts a value in service's store
-spec put_new(id(), term(), term()) ->
    true | false.

put_new(SrvId, Key, Value) ->
    ets:insert_new(SrvId, {Key, Value}).


%% @doc Deletes a value from service's store
-spec del(id(), term()) ->
    ok.

del(SrvId, Key) ->
    true = ets:delete(SrvId, Key),
    ok.


%% @private
get_config(SrvId) ->
   ?CALL_SRV(SrvId, config, []).


%% @private
get_plugins(SrvId) ->
    ?CALL_SRV(SrvId, plugins, []).


%% @private
get_uuid(SrvId) ->
    ?CALL_SRV(SrvId, uuid, []).


%% @private
get_service_workers(SrvId) ->
    nkserver_workers_sup:get_childs(SrvId).


