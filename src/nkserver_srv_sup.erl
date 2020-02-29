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

%% @doc Supervisor for the services
-module(nkserver_srv_sup).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(supervisor).

-export([start_link/3, stop/1, init/1, get_pid/1, get_all/0]).


%% @doc Starts a new service
%% A supervisor is started (registered as {?MODULE, SrvId} with two childs
%% - A worker, registered with the id of the service
%% - Another worker, that tries to register globally in the cluster
%% - A supervisor to start service's childs under
-spec start_link(nkserver:class(), nkserver:id(), nkserver:spec()) ->
    {ok, pid()} | {error, term()}.

start_link(PkgClass, SrvId, Spec) ->
    case get_pid(SrvId) of
        undefined ->
            case nkserver_config:config(SrvId, PkgClass, Spec, #{}) of
                {ok, Service} ->
                    ChildSpec = {{one_for_one, 10, 60}, get_childs(Service)},
                    supervisor:start_link(?MODULE, {SrvId, ChildSpec});
                {error, Error} ->
                    {error, Error}
            end;
        Pid ->
            {error, {already_started, Pid}}
    end.


stop(SrvId) ->
    case get_pid(SrvId) of
        undefined ->
            {error, not_started};
        Pid ->
            sys:terminate(Pid, normal)
    end.


%% @private
get_childs(Service) ->
    [
        #{
            id => supervisor,
            type => supervisor,
            start => {nkserver_workers_sup, start_link, [Service]},
            restart => permanent,
            shutdown => 15000
        },
        #{
            id => server,
            type => worker,
            start => {nkserver_srv, start_link, [Service]},
            restart => permanent,
            shutdown => 15000
        },
        #{
            id => master,
            type => worker,
            start => {nkserver_master, start_link, [Service]},
            restart => permanent,
            shutdown => 15000
        }
    ].


%% @private
init({Id, ChildsSpec}) ->
    ets:new(Id, [named_table, public]),
    yes = nklib_proc:register_name({?MODULE, Id}, self()),
    nklib_proc:put(?MODULE, Id),
    {ok, ChildsSpec}.


%% @doc Get pid() of master supervisor for a service
get_pid(Pid) when is_pid(Pid) ->
    Pid;
get_pid(SrvId) ->
    nklib_proc:whereis_name({?MODULE, SrvId}).


%% @doc Get all services supervisors
get_all() ->
    nklib_proc:values(?MODULE).