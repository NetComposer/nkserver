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

%% @doc Supervisor for the services
-module(nkserver_workers_sup).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(supervisor).

-export([start_link/1, init/1]).
-export([get_pid/1, add_child/2, remove_child/2, remove_all_childs/1, get_childs/1]).
-export([update_child/3, update_child_multi/3]).

-include("nkserver.hrl").



-type update_opts() ::
    #{
        restart_delay => integer()          % msecs
    }.



%% @private
-spec start_link(nkserver:service()) ->
    {ok, pid()} | {error, term()}.

start_link(#{id:=SrvId}) ->
    ChildSpec = {{one_for_one, 10, 60}, []},
    {ok, Pid} = supervisor:start_link(?MODULE, ChildSpec),
    yes = nklib_proc:register_name({?MODULE, SrvId}, Pid),
    {ok, Pid}.



%% @private
%% Shared for main supervisor and service supervisor
init(ChildsSpec) ->
    {ok, ChildsSpec}.


%% @doc Adds a child
-spec add_child(nkserver:id()|pid(), supervisor:child_spec()) ->
    {ok, pid()} | {error, term()}.

add_child(SrvId, Spec) ->
    Pid = get_pid(SrvId),
    case supervisor:start_child(Pid, Spec) of
        {ok, ChildPid} ->
            {ok, ChildPid};
        {error, {already_started, ChildPid}} ->
            {ok, ChildPid};
        {error, already_present} ->
            case supervisor:delete_child(Pid, maps:get(id, Spec)) of
                ok ->
                    add_child(Pid, Spec);
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.



%% @doc Removes a child
-spec remove_child(nkserver:id()|pid(), term()) ->
    ok | {error, term()}.

remove_child(SrvId, ChildId) ->
    Pid = get_pid(SrvId),
    case supervisor:terminate_child(Pid, ChildId) of
        ok ->
            supervisor:delete_child(Pid, ChildId),
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @doc Removes a child
-spec remove_all_childs(nkserver:id()|pid()) ->
    ok.

remove_all_childs(SrvId) ->
    Pid = get_pid(SrvId),
    lists:foreach(
        fun({Id, _ChildPid}) -> remove_child(Pid, Id) end,
        get_childs(SrvId)).


%% @doc Starts or updates a child
%% - If ChildId is not present, starts a new child.
%% - If it is present and has the same Spec, nothing is done
%% - If it is present but has a different Spec, it is restarted (see restart_delay)
%%
-spec update_child(nkserver:id()|pid(), supervisor:child_spec(), update_opts()) ->
    {added, pid()} | {upgraded, pid()} | not_updated | {error, term()}.

update_child(SrvId, #{id:=ChildId}=Spec, Opts) ->
    Pid = get_pid(SrvId),
    case supervisor:get_childspec(Pid, ChildId) of
        {ok, Spec} ->
            not_updated;
        {ok, _OldSpec} ->
            case remove_child(Pid, ChildId) of
                ok ->
                    Delay = maps:get(restart_delay, Opts, 500),
                    timer:sleep(Delay),
                    case supervisor:start_child(Pid, Spec) of
                        {ok, ChildPid} ->
                            {upgraded, ChildPid};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, not_found} ->
            case supervisor:start_child(Pid, Spec) of
                {ok, ChildPid} ->
                    {added, ChildPid};
                {error, Error} ->
                    {error, Error}
            end
    end.




%% @doc Starts or updates a series of childs with the same key, all or nothing
%% ChildIds must be a tuple, first element is the ChildKey
%% (and must be the same in all Specs)
%% - First be remove all childs with the same ChildKey no longer present in Spec
%% - Then we start or update all new (using update_child/3)
%%
-spec update_child_multi(term()|pid(), [supervisor:child_spec()], update_opts()) ->
    ok | upgraded | not_updated | {error, term()}.

update_child_multi(_SrvId, [], _Opts) ->
    not_updated;

update_child_multi(SrvId, SpecList, Opts) ->
    Pid = get_pid(SrvId),
    NewChildIds = [ChildId || #{id:=ChildId} <- SpecList],
    NewChildKeys = [element(1, ChildId) || ChildId <- NewChildIds],
    [ChildKey] = lists:usort(NewChildKeys),
    OldChildIds = [
        ChildId
        || {ChildId, _, _, _} <- supervisor:which_children(Pid),
        element(1, ChildId) == ChildKey
    ],
    ToStop = OldChildIds -- NewChildIds,
    lists:foreach(
        fun(ChildId) ->
            remove_child(Pid, ChildId),
            lager:debug("NkSERVER child ~p (key ~p) stopped", [ChildId, ChildKey])
        end,
        ToStop),
    case update_child_multi(Pid, SpecList, Opts, not_updated) of
        {error, Error} ->
            lager:info("NkSERVER removing all childs for ~p", [ChildKey]),
            lists:foreach(
                fun(ChildId) -> remove_child(Pid, ChildId) end,
                OldChildIds++NewChildIds),
            {error, Error};
        Other ->
            Other
    end.


%% @private
update_child_multi(_Pid, [], _Opts, Res) ->
    Res;

update_child_multi(Pid, [Spec|Rest], Opts, Res) ->
    case update_child(Pid, Spec, Opts) of
        {added, _} ->
            update_child_multi(Pid, Rest, Opts, ok);
        {upgraded, _} ->
            update_child_multi(Pid, Rest, Opts, upgraded);
        not_updated ->
            update_child_multi(Pid, Rest, Opts, Res);
        {error, Error} ->
            {error, Error}
    end.



%% @private Get pid() of master supervisor for all services
get_pid(Pid) when is_pid(Pid) ->
    Pid;
get_pid(SrvId) ->
    nklib_proc:whereis_name({?MODULE, SrvId}).


%% @doc
get_childs(SrvId) ->
    [{I, Pid} || {I, Pid, _, _} <- supervisor:which_children(get_pid(SrvId))].



