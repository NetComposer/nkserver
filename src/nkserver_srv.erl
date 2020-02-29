
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


%% Status management
%% -----------------
%% - Service starts in 'starting' status and all plugins are started
%%   If ok, switches to 'running', if error to 'failing' and is retried later
%% - If the workers supervisor fails, it will switch to 'failing' and plugins
%%   will we started again
%% - If you deactivate it calling set_active(SrvId, false), and it is running,
%%   switches to 'stopping', all plugins are stopped, and, if ok, switches to 'stopped',
%%   if error will stay in 'stopping' and retried later
%% - If you call set_active(SrvId, true), and it is stopping or stopped, switches to
%%   'starting' all plugins will be started again

-module(nkserver_srv).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/1, replace/2, get_status/1, set_active/2]).
-export([get_all_local/0, get_all_local/1, get_service/1]).
-export([get_instances/0, get_instances/1, get_instances/2, get_random_instance/1]).
-export([call/2, call/3, cast/2]).
-export([recompile/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-include("nkserver.hrl").

-define(SRV_CHECK_TIME, 5000).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkSERVER srv '~s' (~s) "++Txt, [State#state.id, State#state.class | Args])).


%% ===================================================================
%% Types
%% ===================================================================


-type id() :: nkserver:id().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc
start_link(#{id:=SrvId}=Service) ->
    gen_server:start_link({local, SrvId}, ?MODULE, Service, []).


%% @doc Replaces a service configuration in local node
-spec replace(id(), nkserver:spec()) ->
    ok | {error, term()}.

replace(SrvId, Spec) ->
    call(SrvId, {nkserver_replace, Spec}, 30000).


%% @doc
-spec get_status(id()) ->
    {ok, nkserver:service_status()} | {error, term()}.

get_status(SrvId) ->
    call(SrvId, nkserver_get_status).


%% @doc
-spec set_active(id(), boolean()) ->
    ok | {error, term()}.

set_active(SrvId, Bool) when is_boolean(Bool) ->
    call(SrvId, {nkserver_set_active, Bool}).


%% @doc
-spec get_service(id()) ->
    {ok, nkserver:service()} | {error, term()}.

get_service(SrvId) ->
    call(SrvId, nkserver_get_service).


%% @doc Synchronous call to the service's gen_server process
-spec call(nkserver:id(), term()) ->
    term().

call(SrvId, Term) ->
    call(SrvId, Term, 5000).


%% @doc Synchronous call to the service's gen_server process with a timeout
-spec call(nkserver:id()|pid(), term(), pos_integer()|infinity|default) ->
    term().

call(SrvId, Term, Time) ->
    nklib_util:call(SrvId, Term, Time).


%% @doc Asynchronous call to the service's gen_server process
-spec cast(nkserver:id()|pid(), term()) ->
    term().

cast(SrvId, Term) ->
    gen_server:cast(SrvId, Term).


%% @doc Gets all started services
-spec get_all_local() ->
    [{id(), nkserver:class(), integer(), pid()}].

get_all_local() ->
    [{SrvId, Class, Hash, Pid} ||
        {{SrvId, Class, Hash}, Pid} <- nklib_proc:values(?MODULE)].


%% @doc Gets all started services
-spec get_all_local(nkserver:class()) ->
    [{id(), nkserver:class(), pid()}].

get_all_local(Class) when is_atom(Class) ->
    [{SrvId, Hash, Pid} || {{SrvId, Hash}, Pid} <- nklib_proc:values({?MODULE, Class})].


%% @doc Gets all started instances
-spec get_instances() ->
    [pid()].

get_instances() ->
    pg2:get_members(?MODULE).


%% @doc Gets all started services for a service
-spec get_instances(nkserver:id()) ->
    [pid()].

get_instances(SrvId) ->
    pg2:get_members({?MODULE, SrvId}).


%% @doc Gets all started services for a service
-spec get_instances(nkserver:id(), binary()) ->
    [pid()].

get_instances(SrvId, Vsn) ->
    pg2:get_members({?MODULE, SrvId, Vsn}).


%% @private Compatibility
get_random_instance(SrvId) ->
    nkserver_srv:get_random_instance(SrvId).



%% @private
recompile(Pid) ->
    gen_server:cast(Pid, nkserver_recompile).


%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    id :: nkserver:id(),
    class :: nkserver:class(),
    vsn :: binary(),
    service :: nkserver:service(),
    status :: nkserver:service_status(),
    worker_sup_pid :: pid(),
    user :: map()
}).


%% @private
init(#{id:=SrvId, class:=Class}=Service) ->
    process_flag(trap_exit, true),          % Allow receiving terminate/2
    case init_srv(Service) of
        ok ->
            {ok, UserState} = ?CALL_SRV(SrvId, srv_init, [Service, #{}]),
            Vsn = maps:get(vsn, Service, <<>>),
            State1 = #state{
                id = SrvId,
                class = Class,
                vsn = Vsn,
                status = #{status => starting, last_status_time => nklib_date:epoch(msecs)},
                service = Service,
                user = UserState
            },
            State2 = set_workers_supervisor(State1),
            % Launch service check
            self() ! nkserver_timed_check_status,
            pg2:create(?MODULE),
            pg2:create({?MODULE, SrvId}),
            pg2:create({?MODULE, SrvId, Vsn}),
            pg2:join(?MODULE, self()),
            ?LLOG(notice, "service server started (~p, ~p)",
                     [State2#state.worker_sup_pid, self()], State2),
            {ok, State2};
        {error, Error} ->
            {stop, Error}
    end.


%% @private
handle_call(nkserver_get_status, _From, State) ->
    {reply, {ok, do_get_status(State)}, State};

handle_call({nkserver_set_active, Bool}, _From, State) ->
    NewStatus = case Bool of
        true -> starting;
        false -> stopping
    end,
    {reply, ok, do_update_status(NewStatus, State)};

handle_call({nkserver_replace, Opts}, _From, State) ->
    case do_update(Opts, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Error} ->
            State2 = do_update_status({error, Error}, State),
            {reply, {error, Error}, State2}
    end;

handle_call(nkserver_get_service, _From, #state{service =Service}=State) ->
    {reply, {ok, Service}, State};

handle_call(nkserver_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, From, State) ->
    case handle(srv_handle_call, [Msg, From], State) of
        continue ->
            ?LLOG(error, "received unexpected call ~p", [Msg], State),
            {noreply, State};
        Other ->
            Other
    end.


%% @private
handle_cast(nkserver_check_status, State)->
    {noreply, check_service_state(State)};

handle_cast(nkserver_stop, State)->
    % Will restart everything
    {stop, normal, State};

handle_cast(nkserver_recompile, #state{service = Service}=State)->
    ok = nkserver_dispatcher:compile(Service),
    {noreply, State};

handle_cast(Msg, State) ->
    case handle(srv_handle_cast, [Msg], State) of
        continue ->
            ?LLOG(error, "received unexpected cast ~p", [Msg], State),
            {noreply, State};
        Other ->
            Other
    end.


%% @private
handle_info(nkserver_timed_check_status, State) ->
    State2 = check_service_state(State),
    State3 = case catch handle(srv_timed_check, [], State2) of
        {ok, TimedState} ->
            TimedState;
        {'EXIT', Error} ->
            ?LLOG(warning, "could not call srv_timed_check: ~p", [Error], State2),
            State2
    end,
    erlang:send_after(?SRV_CHECK_TIME, self(), nkserver_timed_check_status),
    {noreply, State3};

handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{worker_sup_pid =Pid}=State) ->
    ?LLOG(warning, "service supervisor has failed!: ~p", [Reason], State),
    State2 = set_workers_supervisor(State),
    State3 = do_update_status({error, supervisor_failed}, State2),
    {noreply, State3};

handle_info(Msg, State) ->
    case handle(srv_handle_info, [Msg], State) of
        continue ->
            ?LLOG(notice, "received unexpected info ~p", [Msg], State),
            {noreply, State};
        Other ->
            Other
    end.


%% @private
code_change(OldVsn, #state{id=SrvId, user=UserState}=State, Extra) ->
    case apply(SrvId, srv_code_change, [OldVsn, UserState, Extra]) of
        {ok, UserState2} ->
            {ok, State#state{user=UserState2}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
terminate(Reason, State) ->
    ?LLOG(debug, "is stopping (~p)", [Reason], State),
    do_stop_plugins(true, State),
    ?LLOG(info, "is stopped (~p)", [Reason], State),
    catch handle(srv_terminate, [Reason], State).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
init_srv(Service) ->
    #{id:=SrvId, class:=Class, hash:=Hash} = Service,
    nklib_proc:put(?MODULE, {SrvId, Class, Hash}),
    nklib_proc:put({?MODULE, SrvId}, {Class, Hash}),
    nklib_proc:put({?MODULE, Class}, {SrvId, Hash}),
    nkserver_dispatcher:compile(Service).


%% @private
set_workers_supervisor(State) ->
    SupPid = wait_for_supervisor(100, State),
    monitor(process, SupPid),
    State#state{worker_sup_pid = SupPid}.


%% @private
wait_for_supervisor(Tries, #state{id=SrvId}=State) when Tries > 1 ->
    case nkserver_workers_sup:get_pid(SrvId) of
        SupPid when is_pid(SupPid) ->
            SupPid;
        undefined ->
            ?LLOG(notice, "waiting for supervisor (~p tries left)", [Tries], State),
            timer:sleep(100),
            wait_for_supervisor(Tries-1, State)
    end.


%% @private Services will be checked from low to high
%-type status() :: starting | running | updating | stopping | stopped | failing.


check_service_state(#state{status=SrvStatus}=State) ->
    case maps:get(status, SrvStatus) of
        starting ->
            % This ends in running or failing
            do_start_plugins(State);
        failing ->
            % This ends in running or failing
            do_start_plugins(State);
        stopping ->
            % This ends in stopping or stopped
            do_stop_plugins(false, State);
        _ ->
            % running, updating, stopped
            State
    end.


%% @private
do_get_status(State) ->
    #state{
        id = SrvId,
        class = Class,
        vsn = Vsn,
        status = SrvStatus,
        service = Service
    } = State,
    #{hash:=Hash} = Service,
    SrvStatus#{
        id => SrvId,
        class => Class,
        vsn => Vsn,
        pid => self(),
        hash => Hash
    }.


%% @private
%% Will call the service's functions
handle(Fun, Args, #state{id=SrvId, service=Service, user=UserState}=State) ->
    case ?CALL_SRV(SrvId, Fun, Args++[Service, UserState]) of
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
            ?LLOG(warning, "invalid response for ~p(~p): ~p", [Fun, Args, Other], State),
            error(invalid_handle_response)
    end.


%% @private
do_start_plugins(#state{service =Service}=State) ->
    ?LLOG(debug, "starting service plugins", [], State),
    #{expanded_plugins:=Plugins} = Service,
    case do_start_plugins(Plugins, State) of
        ok ->
            do_update_status(running, State);
        {error, Error} ->
            do_stop_plugins(Plugins, State),
            do_update_status({error, Error}, State)
    end.


%% @private
do_start_plugins([], _State) ->
    ok;

do_start_plugins([Id|Rest], #state{id=Id}=State) ->
    do_start_plugins(Rest, State);

do_start_plugins([Plugin|Rest], State) ->
    #state{id=SrvId, service =Service} = State,
    #{config:=Config} = Service,
    Mod = nkserver_config:get_plugin_mod(Plugin),
    % Bottom to top
    ?LLOG(debug, "calling start plugin for ~s (~s)", [Plugin, Mod], State),
    case nklib_util:apply(Mod, plugin_start, [SrvId, Config, Service]) of
        ok ->
            do_start_plugins(Rest, State);
        not_exported ->
            do_start_plugins(Rest, State);
        continue ->
            do_start_plugins(Rest, State);
        {error, Error} ->
            ?LLOG(warning, "error starting plugin ~s service: ~p", [Mod, Error], State),
            {error, Error}
    end.


%% @private
do_stop_plugins(Force, #state{service =Service}=State) ->
    ?LLOG(debug, "stopping service plugins", [], State),
    #{expanded_plugins:=Plugins} = Service,
    case do_stop_plugins(lists:reverse(Plugins), Force, State) of
        ok ->
            do_update_status(stopped, State);
        {error, _Error} ->
            do_update_status(stopping, State)
    end.


%% @private
do_stop_plugins([], _Force, _State) ->
    ok;

do_stop_plugins([Id|Rest], Force, #state{id=Id}=State) ->
    do_stop_plugins(Rest, Force, State);

do_stop_plugins([Plugin|Rest], Force, State) ->
    #state{id=SrvId, service =Service} = State,
    #{config:=Config} = Service,
    Mod = nkserver_config:get_plugin_mod(Plugin),
    ?LLOG(debug, "calling stop plugin for ~s (~s)", [Plugin, Mod], State),
    case nklib_util:apply(Mod, plugin_stop, [SrvId, Config, Service]) of
        {error, Error} when Force ->
            ?LLOG(info, "error stopping plugin ~s service: ~p", [Mod, Error], State),
            do_stop_plugins(Rest, Force, State);
        {error, Error} ->
            ?LLOG(info, "error stopping plugin ~s service: ~p", [Mod, Error], State),
            {error, Error};
        _ ->
            do_stop_plugins(Rest, Force, State)
    end.


%% @private
do_update(Spec, #state{id=SrvId, class=Class, service=Service}=State) ->
    #{class:=Class, hash:=OldHash} = Service,
    case nkserver_config:config(SrvId, Class, Spec, Service) of
        {ok, #{hash:=OldHash}} ->
            % Nothing has changed
            {ok, State};
        {ok, NewService} ->
            State2 = do_update_status(updating, State),
            case do_update_plugins(NewService, State2) of
                ok ->
                    init_srv(NewService),
                    State3 = State2#state{service = NewService},
                    State4 = do_update_status(running, State3),
                    {ok, State4};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_update_plugins(NewService, #state{id=SrvId, class=Class, service =OldService}=State) ->
    #{id:=SrvId, class:=Class, expanded_plugins:=NewPlugins} = NewService,
    #{id:=SrvId, class:=Class, expanded_plugins:=OldPlugins} = OldService,
    ToStop = OldPlugins -- NewPlugins,
    ToStart = NewPlugins -- OldPlugins,
    ToUpdate = OldPlugins -- ToStop -- ToStart,
    ?SRV_LOG(info, "updating service (start:~p, stop:~p, update:~p",
        [ToStart, ToStop, ToUpdate], OldService),
    do_stop_plugins(ToStop, State),
    case do_update_plugins(ToUpdate, NewService, State) of
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
do_update_plugins([], _NewService, _State) ->
    ok;

do_update_plugins([Id|Rest], NewService, #state{id=Id}=State) ->
    do_update_plugins(Rest, NewService, State);

do_update_plugins([Plugin|Rest], NewService, State) ->
    #state{id=SrvId, service =Service} = State,
    Mod = nkserver_config:get_plugin_mod(Plugin),
    #{config:=NewConfig} = NewService,
    #{config:=OldConfig} = Service,
    Args = [SrvId, NewConfig, OldConfig, NewService],
    ?LLOG(debug, "calling update plugin for ~s (~s)", [Plugin, Mod], State),
    case nklib_util:apply(Mod, plugin_update, Args) of
        ok ->
            do_update_plugins(Rest, NewService, State);
        not_exported ->
            do_update_plugins(Rest, NewService, State);
        continue ->
            do_update_plugins(Rest, NewService, State);
        {error, Error} ->
            ?LLOG(warning, "error updating plugin ~s service: ~p", [Mod, Error], State),
            {error, Error}
    end.


%% @private
do_update_status({error, Error}, #state{id=SrvId, vsn=Vsn, status=SrvStatus}=State) ->
    pg2:leave({?MODULE, SrvId}, self()),
    pg2:leave({?MODULE, SrvId, Vsn}, self()),
    Now = nklib_date:epoch(msecs),
    ?LLOG(notice, "service status 'failed': ~p", [Error], State),
    SrvStatus2 = SrvStatus#{
        status => failing,
        last_error => Error,
        last_error_time => Now,
        last_status_time => Now
    },
    State#state{status=SrvStatus2};

do_update_status(NewStatus, #state{id=SrvId, vsn=Vsn, status=SrvStatus}=State) ->
    case maps:get(status, SrvStatus) of
        NewStatus ->
            State;
        running when NewStatus==starting ->
            State;
        stopped when NewStatus==stopping ->
            State;
        Status ->
            case NewStatus of
                running ->
                    pg2:join({?MODULE, SrvId}, self()),
                    pg2:join({?MODULE, SrvId, Vsn}, self());
                _ ->
                    pg2:leave({?MODULE, SrvId}, self()),
                    pg2:leave({?MODULE, SrvId, Vsn}, self())
            end,
            ?LLOG(notice, "service status updated '~s' -> '~s'",
                     [Status, NewStatus], State),
            SrvStatus2 = SrvStatus#{
                status => NewStatus,
                last_status_time => nklib_date:epoch(msecs)
            },
            State#state{status=SrvStatus2}
    end.

