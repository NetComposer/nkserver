
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


%% Package management
%% -----------------
%%
%% When the service starts, packages_status is empty
%% - All defined packages will be launched in check_packages, low first
%% - Packages can return running or failed
%% - Periodically we re-launch start for failed ones
%% - If the package supervisor fails, it is marked as failed
%%
%% When the service is updated
%% - Packages no longer available are removed, and called stop_package
%% - Packages that stay are marked as upgrading, called update_package
%% - When response is received, they are marked as running or failed
%%
%% Package stop
%% - Packages are stopped sequentially (high to low)


-module(nkserver_srv).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/1, replace/2, get_status/1]).
-export([get_local_all/0, get_local_all/1, get_all_status/0, get_all_status/1]).
-export([stop_local_all/0, stop_local_all/1, get_package/1]).
-export([call/2, call/3, cast/2]).
-export([get_package_childs/1, recompile/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-include("nkserver.hrl").

-define(SRV_CHECK_TIME, 5000).

-define(SRV_LOG(Type, Txt, Args, State),
    lager:Type("NkSERVER '~s' (~s) "++Txt, [State#state.id, State#state.class | Args])).


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: nkserver:id().

-type status() :: starting | running | updating | failed.

-type package_status() ::
    #{
        id => nkserver:id(),
        class => nkserver:class(),
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
start_link(#{id:=PkgId}=Package) ->
    gen_server:start_link({local, PkgId}, ?MODULE, Package, []).


%% @doc Replaces a service configuration in local node
-spec replace(id(), nkserver:spec()) ->
    ok | {error, term()}.

replace(PkgId, Spec) ->
    call(PkgId, {nkserver_replace, Spec}, 30000).


%% @doc
-spec get_status(id()) ->
    {ok, package_status()} | {error, term()}.

get_status(PkgId) ->
    call(PkgId, nkserver_get_status).


%% @doc
-spec get_package(id()) ->
    {ok, nkserver:package()} | {error, term()}.

get_package(PkgId) ->
    call(PkgId, nkserver_get_package).


%% @doc Synchronous call to the service's gen_server process
-spec call(nkserver:id(), term()) ->
    term().

call(PkgId, Term) ->
    call(PkgId, Term, 5000).


%% @doc Synchronous call to the service's gen_server process with a timeout
-spec call(nkserver:id()|pid(), term(), pos_integer()|infinity|default) ->
    term().

call(PkgId, Term, Time) ->
    nklib_util:call(PkgId, Term, Time).


%% @doc Asynchronous call to the service's gen_server process
-spec cast(nkserver:id()|pid(), term()) ->
    term().

cast(PkgId, Term) ->
    gen_server:cast(PkgId, Term).


%% @doc Gets all started services
-spec get_local_all() ->
    [{id(), nkserver:class(), integer(), pid()}].

get_local_all() ->
    [{PkgId, Class, Hash, Pid} ||
        {{PkgId, Class, Hash}, Pid} <- nklib_proc:values(nkserver_srv)].


%% @doc Gets all started services
-spec get_local_all(nkserver:class()) ->
    [{id(), pid()}].

get_local_all(Class) ->
    Class2 = nklib_util:to_binary(Class),
    [{PkgId, Pid} || {PkgId, C, _H, Pid} <- get_local_all(), C==Class2].


%% @doc Gets all instances in all nodes
get_all_status() ->
    lists:foldl(
        fun(Pid, Acc) ->
            case catch get_status(Pid) of
                {ok, Status} -> [Status|Acc];
                _ -> Acc
            end
        end,
        [],
        pg2:get_members(?MODULE)).


%% @doc Gets all instances in all nodes
get_all_status(Class) ->
    Class2 = nklib_util:to_binary(Class),
    [Status || Status<-get_all_status(), {ok, Class2} == maps:find(class, Status)].


%% @doc Stops all started services
-spec stop_local_all() ->
    ok.

stop_local_all() ->
    PkgIds = [PkgId || {PkgId, _Class, _Hash, _Pid} <- get_local_all()],
    lists:foreach(fun(PkgId) -> nksip:stop(PkgId) end, PkgIds).


%% @doc Gets all started services
-spec stop_local_all(nkserver:class()) ->
    ok.

stop_local_all(Class) ->
    PkgIds = [PkgId || {PkgId, _Pid} <- get_local_all(Class)],
    lists:foreach(fun(PkgId) -> nksip:stop(PkgId) end, PkgIds).


%% @private
get_package_childs(PkgId) ->
    nkserver_workers_sup:get_childs(PkgId).


%% @private
recompile(Pid) ->
    gen_server:cast(Pid, nkserver_recompile).


%% ===================================================================
%% gen_server
%% ===================================================================



-record(state, {
    id :: nkserver:id(),
    class :: nkserver:class(),
    package :: nkserver:package(),
    package_status :: package_status(),
    worker_sup_pid :: pid(),
    user :: map()
}).



%% @private
init(#{id:=PkgId, class:=Class}=Package) ->
    process_flag(trap_exit, true),          % Allow receiving terminate/2
    init_package_srv(Package),
    {ok, UserState} = ?CALL_PKG(PkgId, package_srv_init, [Package, #{}]),
    State1 = #state{
        id = PkgId,
        class = Class,
        package_status = #{
            status => init,
            last_status_time => nklib_date:epoch(msecs)
        },
        package = Package,
        user = UserState
    },
    State2 = set_workers_supervisor(State1),
    self() ! nkserver_timed_check_status,
    pg2:create(?MODULE),
    pg2:join(?MODULE, self()),
    pg2:create({?MODULE, PkgId}),
    pg2:join({?MODULE, PkgId}, self()),
    ?SRV_LOG(notice, "package server started (~p, ~p)",
             [State2#state.worker_sup_pid, self()], State2),
    {ok, State2}.


%% @private
handle_call(nkserver_get_status, _From, State) ->
    {reply, {ok, do_get_status(State)}, State};

handle_call({nkserver_replace, Opts}, _From, State) ->
    case do_update(Opts, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Error} ->
            State2 = update_status({error, Error}, State),
            {reply, {error, Error}, State2}
    end;

handle_call(nkserver_get_package, _From, #state{package=Package}=State) ->
    {reply, {ok, Package}, State};

handle_call(nkserver_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) ->
    case handle(package_srv_handle_call, [Msg, From], State) of
        continue ->
            ?SRV_LOG(error, "received unexpected call ~p", [Msg], State),
            {noreply, State};
        Other ->
            Other
    end.


%% @private
handle_cast(nkserver_check_status, State)->
    {noreply, check_package_state(State)};

handle_cast(nkserver_stop, State)->
    % Will restart everything
    {stop, normal, State};

handle_cast(nkserver_recompile, #state{package = Package}=State)->
    nkserver_dispatcher:compile(Package),
    {noreply, State};

handle_cast(Msg, State) ->
    case handle(package_srv_handle_cast, [Msg], State) of
        continue ->
            ?SRV_LOG(error, "received unexpected cast ~p", [Msg], State),
            {noreply, State};
        Other ->
            Other
    end.


%% @private
handle_info(nkserver_timed_check_status, State) ->
    State2 = check_package_state(State),
    State3 = case catch handle(package_srv_timed_check, [], State2) of
        {ok, TimedState} ->
            TimedState;
        {'EXIT', Error} ->
            ?SRV_LOG(warning, "could not call package_srv_timed_check: ~p", [Error], State2),
            State2
    end,
    erlang:send_after(?SRV_CHECK_TIME, self(), nkserver_timed_check_status),
    {noreply, State3};

handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{worker_sup_pid =Pid}=State) ->
    ?SRV_LOG(warning, "package supervisor has failed!: ~p", [Reason], State),
    State2 = set_workers_supervisor(State),
    State3 = update_status({error, supervisor_failed}, State2),
    {noreply, State3};

handle_info(Msg, State) ->
    case handle(package_srv_handle_info, [Msg], State) of
        continue ->
            ?SRV_LOG(notice, "received unexpected info ~p", [Msg], State),
            {noreply, State};
        Other ->
            Other
    end.


%% @private
code_change(OldVsn, #state{id=PkgId, user=UserState}=State, Extra) ->
    case apply(PkgId, package_srv_code_change, [OldVsn, UserState, Extra]) of
        {ok, UserState2} ->
            {ok, State#state{user=UserState2}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
terminate(Reason, State) ->
    ?SRV_LOG(debug, "is stopping (~p)", [Reason], State),
    do_stop_plugins(State),
    ?SRV_LOG(info, "is stopped (~p)", [Reason], State),
    catch handle(package_srv_terminate, [Reason], State).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
init_package_srv(Package) ->
    #{id:=PkgId, class:=Class, hash:=Hash} = Package,
    nklib_proc:put(?MODULE, {PkgId, Class, Hash}),
    nklib_proc:put({?MODULE, PkgId}, {Class, Hash}),
    nkserver_dispatcher:compile(Package),
    nkserver_util:notify_updated_service(PkgId).


%% @private
set_workers_supervisor(State) ->
    SupPid = wait_for_supervisor(10, State),
    monitor(process, SupPid),
    State#state{worker_sup_pid = SupPid}.


%% @private
wait_for_supervisor(Tries, #state{id=PkgId}=State) when Tries > 0 ->
    case nkserver_workers_sup:get_pid(PkgId) of
        SupPid when is_pid(SupPid) ->
            SupPid;
        undefined ->
            ?SRV_LOG(notice, "waiting for supervisor (~p tries left)", [Tries], State),

            timer:sleep(100),
            wait_for_supervisor(Tries-1, State)
    end;

wait_for_supervisor(_Tries, State) ->
    ?SRV_LOG(error, "could not start supervisor", [], State),
    error(could_not_find_supervidor).


%% @private Packages will be checked from low to high
check_package_state(#state{package_status=PkgStatus}=State) ->
    case maps:get(status, PkgStatus) of
        init ->
            do_start_plugins(State);
        failed ->
            do_start_plugins(State);
        _ ->
            State
    end.


%% @private
do_get_status(State) ->
    #state{
        id = PkgId,
        class = Class,
        package_status = PkgStatus,
        package = Package
    } = State,
    #{hash:=Hash} = Package,
    PkgStatus#{
        id => PkgId,
        class => Class,
        pid => self(),
        hash => Hash
    }.


%% @private
%% Will call the service's functions
handle(Fun, Args, #state{id=PkgId, package=Package, user=UserState}=State) ->
    case ?CALL_PKG(PkgId, Fun, Args++[Package, UserState]) of
        {reply, Reply, UserState2} ->
            {reply, Reply, State#state{user=UserState2}};
        {reply, Reply, UserState2, Time} ->
            {reply, Reply, State#state{user=UserState2}, Time};
        {noreply, UserState2} ->
            {noreply, State#state{user=UserState2}};
        {noreply, UserState2, Time} ->
            {noreply, State#state{user=UserState2}, Time};
        {stop, Reason, Reply, UserState2} ->
            {stop, Reason, Reply, State#state{user=UserState2}};
        {stop, Reason, UserState2} ->
            {stop, Reason, State#state{user=UserState2}};
        {ok, UserState2} ->
            {ok, State#state{user=UserState2}};
        continue ->
            continue;
        Other ->
            ?SRV_LOG(warning, "invalid response for ~p(~p): ~p", [Fun, Args, Other], State),
            error(invalid_handle_response)
    end.


%% @private
do_start_plugins(#state{package=Package}=State) ->
    ?SRV_LOG(debug, "starting package plugins", [], State),
    #{expanded_plugins:=Plugins} = Package,
    case do_start_plugins(Plugins, State) of
        ok ->
            update_status(running, State);
        {error, Error} ->
            do_stop_plugins(Plugins, State),
            update_status({error, Error}, State)
    end.


%% @private
do_start_plugins([], _State) ->
    ok;

do_start_plugins([Id|Rest], #state{id=Id}=State) ->
    do_start_plugins(Rest, State);

do_start_plugins([Plugin|Rest], State) ->
    #state{id=PkgId, class=Class, package=Package} = State,
    #{config:=Config} = Package,
    Mod = nkserver_config:get_plugin_mod(Plugin),
    % Bottom to top
    ?SRV_LOG(debug, "calling start plugin for ~s (~s)", [Plugin, Mod], State),
    case nklib_util:apply(Mod, plugin_start, [PkgId, Class, Config, Package]) of
        ok ->
            do_start_plugins(Rest, State);
        not_exported ->
            do_start_plugins(Rest, State);
        continue ->
            do_start_plugins(Rest, State);
        {error, Error} ->
            ?SRV_LOG(warning, "error starting plugin ~s package: ~p", [Mod, Error], State),
            {error, Error}
    end.


%% @private
do_stop_plugins(#state{package=Package}=State) ->
    ?SRV_LOG(debug, "stopping package plugins", [], State),
    #{expanded_plugins:=Plugins} = Package,
    do_stop_plugins(lists:reverse(Plugins), State).


%% @private
do_stop_plugins([], _State) ->
    ok;

do_stop_plugins([Id|Rest], #state{id=Id}=State) ->
    do_stop_plugins(Rest, State);

do_stop_plugins([Plugin|Rest], State) ->
    #state{id=PkgId, class=Class, package=Package} = State,
    #{config:=Config} = Package,
    Mod = nkserver_config:get_plugin_mod(Plugin),
    ?SRV_LOG(debug, "calling stop plugin for ~s (~s)", [Plugin, Mod], State),
    case nklib_util:apply(Mod, plugin_stop, [PkgId, Class, Config, Package]) of
        {error, Error} ->
            ?SRV_LOG(info, "error stopping plugin ~s package: ~p", [Mod, Error], State);
        _ ->
            ok
    end,
    do_stop_plugins(Rest, State).


%% @private
do_update(Opts, #state{id=PkgId, class=Class, package=Package}=State) ->
    #{class:=Class, hash:=OldHash} = Package,
    case nkserver_util:get_spec(PkgId, Class, Opts) of
        {ok, Spec} ->
            case nkserver_config:config(Spec, Package) of
                {ok, #{hash:=OldHash}} ->
                    % Nothing has changed
                    {ok, State};
                {ok, NewPackage} ->
                    case do_update_plugins(NewPackage, State) of
                        ok ->
                            init_package_srv(NewPackage),
                            State2 = State#state{package = NewPackage},
                            State3 = update_status(running, State2),
                            {ok, State3};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_update_plugins(NewPackage, #state{id=PkgId, class=Class, package=OldPackage}=State) ->
    #{id:=PkgId, class:=Class, expanded_plugins:=NewPlugins} = NewPackage,
    #{id:=PkgId, class:=Class, expanded_plugins:=OldPlugins} = OldPackage,
    ToStop = OldPlugins -- NewPlugins,
    ToStart = NewPlugins -- OldPlugins,
    ToUpdate = OldPlugins -- ToStop -- ToStart,
    ?PKG_LOG(info, "updating package (start:~p, stop:~p, update:~p",
        [ToStart, ToStop, ToUpdate], OldPackage),
    do_stop_plugins(ToStop, State),
    case do_update_plugins(ToUpdate, NewPackage, State) of
        ok ->
            case do_start_plugins(ToStart, State) of
                ok ->
                    ok;
                {error, Error} ->
                    do_stop_plugins(lists:usort(NewPlugins++OldPlugins), State),
                    {error, Error}
            end;
        {error, Error} ->
            do_stop_plugins(OldPlugins, State),
            {error, Error}
    end.


%% @private
do_update_plugins([], _NewPackage, _State) ->
    ok;

do_update_plugins([Id|Rest], NewPackage, #state{id=Id}=State) ->
    do_update_plugins(Rest, NewPackage, State);

do_update_plugins([Plugin|Rest], NewPackage, State) ->
    #state{id=PkgId, class=Class, package=Package} = State,
    Mod = nkserver_config:get_plugin_mod(Plugin),
    #{config:=NewConfig} = NewPackage,
    #{config:=OldConfig} = Package,
    Args = [PkgId, Class, NewConfig, OldConfig, NewPackage],
    ?SRV_LOG(debug, "calling update plugin for ~s (~s)", [Plugin, Mod], State),
    case nklib_util:apply(Mod, plugin_update, Args) of
        ok ->
            do_update_plugins(Rest, NewPackage, State);
        not_exported ->
            do_update_plugins(Rest, NewPackage, State);
        continue ->
            do_update_plugins(Rest, NewPackage, State);
        {error, Error} ->
            ?SRV_LOG(warning, "error updating plugin ~s package: ~p", [Mod, Error], State),
            {error, Error}
    end.


%% @private
update_status({error, Error}, #state{package_status=PkgStatus}=State) ->
    Now = nklib_date:epoch(msecs),
    ?SRV_LOG(notice, "package status 'failed': ~p", [Error], State),
    PkgStatus2 = PkgStatus#{
        status => failed,
        last_error => Error,
        last_error_time => Now,
        last_status_time => Now
    },
    State#state{package_status = PkgStatus2};

update_status(Status, #state{package_status=PkgStatus}=State) ->
    case maps:get(status, PkgStatus) of
        Status ->
            State;
        OldStatus ->
            Now = nklib_date:epoch(msecs),
            ?SRV_LOG(notice, "package status updated '~s' -> '~s'",
                     [OldStatus, Status], State),
            PkgStatus2 = PkgStatus#{
                status => Status,
                last_status_time => Now
            },
            State#state{package_status = PkgStatus2}
    end.





%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).
