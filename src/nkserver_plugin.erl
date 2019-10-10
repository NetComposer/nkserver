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

%% @doc Default callbacks for plugin definitions
-module(nkserver_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([plugin_deps/0, plugin_meta/0, plugin_config/3, plugin_cache/3,
          plugin_start/3, plugin_update/4, plugin_stop/3]).
-export_type([continue/0]).

-import(nklib_util, [to_list/1]).


-type id() :: nkserver:id().
-type service() :: nkserver:service().
-type config() :: config().
-type continue() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @doc Called to get the list of plugins this service/plugin depends on.
%% If the option 'optional' is used, and the plugin could not be loaded, it is ignored
-callback plugin_deps() ->
    [module() | {module(), optional}].


%% @doc Optionally set a number of parameters for the plugin
%% Currently supported are:
%% - group:
%%      all plugins within a group are added a dependency on the previous defined plugins
%%      in the same group. This way, the order of callbacks is the same as the order
%%      plugins are defined in this group.
%% - use_master:
%%      boolean to set this plugin uses the plugin master
-callback plugin_meta() ->
    #{group=>term(), use_master=>boolean()} | undefined.


%% @doc This function must parse any configuration for this plugin,
%% and can optionally modify it
%% Top-level plugins will be called first, so they can set up configurations for low-level
%% Plugins must keep unknown options to be use by next plugins
%% It is recommended to use nkserver_util:parse_config/2
-callback plugin_config(id(), config(), service()) ->
    ok | {ok, config()} | {error, term()}.


%% @doc This function, if implemented, is called after all configuration have been
%% processed, and before starting any service.
%% The returned map is stored as an Erlang term inside the dispatcher module,
%% and can be retrieved calling nkserver:get_config/3
%% An undocumented third param can be used to add compiled callbacks,
%% see nkactor_plugin
-callback plugin_cache(id(), config(), service()) ->
    ok | {ok, map()} | {error, term()}.


%% @doc Called during service's start
%% All plugins are started in parallel. If a plugin depends on another,
%% it can wait for a while, checking nkserver_srv_plugin_sup:get_pid/2 or
%% calling nkserver_srv:get_status/1
%% This call is non-blocking, called at each node
-callback plugin_start(id(), config(), service()) ->
    ok | {error, term()}.


%% @doc Called during service's stop
%% The supervisor pid, if started, if passed
%% After the call, the supervisor will be stopped
%% This call is non-blocking, except for full service stop
-callback plugin_stop(id(), config(), service()) ->
    ok | {error, term()}.



%% @doc Called during service's update, for plugins with updated configuration
%% This call is non-blocking, called at each node
-callback plugin_update(id(), New::config(), Old::config(),
                        service()) ->
    ok | {error, term()}.



%% ===================================================================
%% Default implementation
%% ===================================================================



plugin_deps() ->
	[].


plugin_meta() ->
	#{}.


plugin_config(_Id, _Config, _Service) ->
    ok.

plugin_cache(_Id, Config, _Service) ->
    Syntax = #{debug=>boolean},
    case nklib_syntax:parse_all(Config, Syntax) of
        {ok, Parsed} ->
            Cache = #{
                debug => maps:get(debug, Parsed, false)
            },
            {ok, Cache};
        _ ->
            ok
    end.


plugin_start(_Id, _Config, _Service) ->
    ok.


plugin_stop(_Id, _Config, _Service) ->
	ok.


plugin_update(_Id, _NewConfig, _OldConfig, _Service) ->
    ok.



%% ===================================================================
%% Internal
%% ===================================================================
