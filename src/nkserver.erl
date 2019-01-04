%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([start_link/3, get_sup_spec/3]).
-export([update/2, replace/2]).
-export([get_all_status/0, get_all_status/1]).
-export([get_plugin_config/3, get/2, get/3, put/3, put_new/3, del/2]).
-export([uuid/1]).
-export_type([id/0, class/0, spec/0, package/0]).


-include("nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: module().

-type class() :: binary().

-type config() :: map().

-type spec() ::
    #{
        uuid => binary(),
        plugins => binary(),
        term() => term()
    }.


-type package() ::
    #{
        id => module(),
        class => class(),
        uuid => binary(),
        plugins => [atom()],
        expanded_plugins => [atom()],         % Expanded,bottom to top
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

start_link(PkgClass, PkgId, Spec) ->
    nkserver_package_sup:start_link(PkgClass, PkgId, Spec).


%% @doc
-spec get_sup_spec(class(), id(), spec()) ->
    {ok, pid()} | {error, term()}.

get_sup_spec(PkgClass, PkgId, Spec) ->
    #{
        id => {nkserver, PkgId},
        start => {?MODULE, start_link, [PkgClass, PkgId, Spec]},
        restart => permanent,
        shutdown => 15000,
        type => supervisor
    }.


%% @doc Updates a service configuration in local node
-spec update(id(), spec()) ->
    ok | {error, term()}.

update(PkgId, Spec) ->
    OldConfig = ?CALL_PKG(PkgId, config, []),
    Spec2 = maps:merge(OldConfig, Spec),
    replace(PkgId, Spec2).


%% @doc Updates a service configuration in local node
-spec replace(id(), spec()) ->
    ok | {error, term()}.

replace(PkgId, Spec) ->
    nkserver_srv:replace(PkgId, Spec).



%% @doc Gets all instances in all nodes
get_all_status() ->
    nkserver_srv:get_all_status().


%% @doc Gets all instances in all nodes
get_all_status(Class) ->
    nkserver_srv:get_all_status(Class).


%% @doc Get a plugin configuration
get_plugin_config(PkgId, PluginId, Key) ->
    ?CALL_PKG(PkgId, config_cache, [PluginId, Key]).


%% @doc Gets a value from service's store
-spec get(id(), term()) ->
    term().

get(PkgId, Key) ->
    get(PkgId, Key, undefined).


%% @doc Gets a value from service's store
-spec get(id(), term(), term()) ->
    term().

get(PkgId, Key, Default) ->
    case ets:lookup(PkgId, Key) of
        [{_, Value}] -> Value;
        [] -> Default
    end.


%% @doc Inserts a value in service's store
-spec put(id(), term(), term()) ->
    ok.

put(PkgId, Key, Value) ->
    true = ets:insert(PkgId, {Key, Value}),
    ok.


%% @doc Inserts a value in service's store
-spec put_new(id(), term(), term()) ->
    true | false.

put_new(PkgId, Key, Value) ->
    ets:insert_new(PkgId, {Key, Value}).


%% @doc Deletes a value from service's store
-spec del(id(), term()) ->
    ok.

del(PkgId, Key) ->
    true = ets:delete(PkgId, Key),
    ok.


uuid(PkgId) ->
    ?CALL_PKG(PkgId, uuid, []).
