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

-module(nkserver_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([register_package_class/2, register_package_class/3,
         get_package_class_module/1, get_package_class_meta/1]).
-export([name/1, parse_config/2]).
-export([register_for_changes/1, notify_updated_service/1]).
-export([get_net_ticktime/0, set_net_ticktime/2]).
-export([handle_user_call/5]).

-include("nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type register_opts() ::
    #{
        use_master => boolean()
    }.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec register_package_class(nkserver:package_class(), module()) ->
    ok.

register_package_class(Class, Module) ->
    register_package_class(Class, Module, #{}).


%% @doc
-spec register_package_class(nkserver:package_class(), module(), register_opts()) ->
    ok.

register_package_class(Class, Module, Opts) when is_atom(Module), is_map(Opts) ->
    nklib_types:register_type(nkserver_package_class, to_bin(Class), Module, Opts).


%% @doc
-spec get_package_class_module(nkserver:package_class()) ->
    module() | undefined.

get_package_class_module(Class) ->
    nklib_types:get_module(nkserver_package_class, to_bin(Class)).


%% @doc
-spec get_package_class_meta(nkserver:package_class()) ->
    module() | undefined.

get_package_class_meta(Class) ->
    nklib_types:get_meta(nkserver_package_class, to_bin(Class)).


%% @doc Registers a pid to receive changes in service config
-spec register_for_changes(nkserver:id()) ->
    ok.

register_for_changes(SrvId) ->
    nklib_proc:put({notify_updated_service, SrvId}).


%% @doc
-spec notify_updated_service(nkserver:id()) ->
    ok.

notify_updated_service(SrvId) ->
    lists:foreach(
        fun({_, Pid}) -> Pid ! {nkserver_updated, SrvId} end,
        nklib_proc:values({notify_updated_service, SrvId})).

%% @private
name(Name) ->
    nklib_parse:normalize(Name, #{space=>$_, allowed=>[$+, $-, $., $_]}).


%% @doc
parse_config(Config, Syntax) ->
    nklib_syntax:parse_all(Config, Syntax).




%%%% @doc
%%luerl_api(SrvId, PackageId, Mod, Fun, Args, St) ->
%%    try
%%        Res = case apply(Mod, Fun, [SrvId, PackageId, Args]) of
%%            {error, Error} ->
%%                {Code, Txt} = nkserver_msg:msg(SrvId, Error),
%%                [nil, Code, Txt];
%%            Other when is_list(Other) ->
%%                Other
%%        end,
%%        {Res, St}
%%    catch
%%        Class:CError:Trace ->
%%            lager:notice("NkSERVER LUERL ~s (~s, ~s:~s(~p)) API Error ~p:~p ~p",
%%                [SrvId, PackageId, Mod, Fun, Args, Class, CError, Trace]),
%%            {[nil], St}
%%    end.


%% @private
get_net_ticktime() ->
    rpc:multicall(net_kernel, get_net_ticktime, []).


%% @private
set_net_ticktime(Time, Period) ->
    rpc:multicall(net_kernel, set_net_ticktime, [Time, Period]).


%% @private
%% Will call the service's functions
handle_user_call(Fun, Args, State, PosSrvId, PosUserState) ->
    SrvId = element(PosSrvId, State),
    UserState = element(PosUserState, State),
    Args2 = Args ++ [UserState],
    case ?CALL_SRV(SrvId, Fun, Args2) of
        {reply, Reply, UserState2} ->
            State2 = setelement(PosUserState, State, UserState2),
            {reply, Reply, State2};
        {reply, Reply, UserState2, Time} ->
            State2 = setelement(PosUserState, State, UserState2),
            {reply, Reply, State2, Time};
        {noreply, UserState2} ->
            State2 = setelement(PosUserState, State, UserState2),
            {noreply, State2};
        {noreply, UserState2, Time} ->
            State2 = setelement(PosUserState, State, UserState2),
            {noreply, State2, Time};
        {stop, Reason, Reply, UserState2} ->
            State2 = setelement(PosUserState, State, UserState2),
            {stop, Reason, Reply, State2};
        {stop, Reason, UserState2} ->
            State2 = setelement(PosUserState, State, UserState2),
            {stop, Reason, State2};
        {ok, UserState2} ->
            State2 = setelement(PosUserState, State, UserState2),
            {ok, State2};
        continue ->
            continue;
        Other ->
            lager:warning("invalid response for ~p:~p(~p): ~p", [SrvId, Fun, Args, Other]),
            error(invalid_handle_response)
    end.



%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).



