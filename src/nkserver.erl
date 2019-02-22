%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([start_link/3, get_sup_spec/3, stop/1]).
-export([update/2, replace/2]).
-export([get_all_status/0, get_all_status/1]).
-export([get_plugin_config/3, get/2, get/3, put/3, put_new/3, del/2]).
-export([get_config/1, get_plugins/1, get_uuid/1]).
-export_type([id/0, class/0, spec/0, service/0]).


-include("nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: module().

-type class() :: binary().

-type config() :: map().

% If 'use_module' is used, id is ignored as a callback module,
% a new one is compiled from scratch based on 'use_module'
-type spec() ::
    #{
        uuid => binary(),
        plugins => binary(),
        use_module => module(),
        use_master => boolean(),
        master_min_nodes => pos_integer(),
        term() => term()
    }.


-type service() ::
    #{
        id => module(),
        class => class(),
        uuid => binary(),
        plugins => [atom()],
        expanded_plugins => [atom()],         % Expanded,bottom to top
        use_module => module(),
        user_master => boolean(),
        master_min_nodes => pos_integer(),
        timestamp => nklib_date:epoch(msecs),
        hash => integer(),
        config => config()
    }.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec start_link(class(), id(), spec()) ->
    {ok, pid()} | {error, term()}.

start_link(PkgClass, SrvId, Spec) when is_atom(SrvId), is_map(Spec) ->
    nkserver_srv_sup:start_link(nklib_util:to_binary(PkgClass), SrvId, Spec).


%% @doc
-spec get_sup_spec(class(), id(), spec()) ->
    {ok, pid()} | {error, term()}.

get_sup_spec(PkgClass, SrvId, Spec) when is_atom(SrvId), is_map(Spec) ->
    #{
        id => {nkserver, SrvId},
        start => {?MODULE, start_link, [nklib_util:to_binary(PkgClass), SrvId, Spec]},
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



%% @doc Gets all instances in all nodes
get_all_status() ->
    nkserver_srv:get_status_all().


%% @doc Gets all instances in all nodes
get_all_status(Class) ->
    nkserver_srv:get_status_all(Class).


%% @doc Get a plugin configuration
get_plugin_config(SrvId, PluginId, Key) ->
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

