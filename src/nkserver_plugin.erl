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
-export([plugin_deps/0, plugin_group/0, plugin_config/3, plugin_cache/3,
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


%% @doc Optionally set the plugin 'group'
%% All plugins within a group are added a dependency on the previous defined plugins
%% in the same group.
%% This way, the order of callbacks is the same as the order plugins are defined
%% in this group.
-callback plugin_group() ->
    term() | undefined.


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


plugin_group() ->
	undefined.


plugin_config(_Id, Config, _Service) ->
    Syntax = #{
        opentrace_url => binary,
        opentrace_filter => binary
    },
    nkserver_util:parse_config(Config, Syntax).


plugin_cache(_Id, _Config, _Service) ->
    ok.


plugin_start(_Id, Config, _Service) ->
    update_otters(Config),
    ok.


plugin_stop(_Id, _Config, _Service) ->
	ok.


plugin_update(_Id, NewConfig, _OldConfig, _Service) ->
    update_otters(NewConfig),
    ok.



%% ===================================================================
%% Internal
%% ===================================================================

update_otters(Config) ->
    case maps:find(opentrace_url, Config) of
        {ok, Url} ->
            ok = application:set_env(otters, zipkin_collector_uri, to_list(Url)),
            case maps:find(opentrace_filter, Config) of
                {ok, Filter} ->
                    ok = ol:compile(to_list(Filter));
                error ->
                    ol:clear()
            end;
        error ->
            ok
    end.




%%{zipkin_collector_uri,"http://127.0.0.1:9411/api/v1/spans"},
%%%{zipkin_collector_uri, "http://127.0.0.1:14268/api/traces?format=zipkin.thrift"},
%%{zipkin_batch_interval_ms, 100},
%%{zipkin_tag_host_ip, {127,0,0,1}},
%%{zipkin_tag_host_port, 0},
%%{zipkin_tag_host_service, "netcomp_smspro"},
%%{zipkin_add_default_service_to_logs, false},
%%{zipkin_add_default_service_to_tags, false},
%%{zipkin_add_host_tag_to_span,{"lc",[]}}


