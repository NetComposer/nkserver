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

-module(nkserver_status).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_defined/2, extended_status/2, status/2]).
-export_type([user_status/0, desc_status/0, expanded_status/0]).
-include("nkserver.hrl").

-type user_status() :: term().

-type desc_status() ::
    string() |
    expanded_status() |
    {string(), list()} |
    {string(), expanded_status()} |
    {string(), list(), expanded_status()}.

-type expanded_status() ::
    #{
        status := binary(),
        info => binary(),
        code => integer(),
        data => map()
    }.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Expands a server message
%% - First, if it is an atom or tuple, callback msg/1 is called for this service
%% - If not, it is managed as a non-standard msg if it is valid nkserver:status()
%% - If it is not, a generic code is returned and an error is printed
-spec extended_status(nkserver:id(), user_status()) ->
    expanded_status().

extended_status(SrvId, UserStatus) ->
    case get_defined(SrvId, UserStatus) of
        {true, ExpandedStatus} ->
            ExpandedStatus;
        false ->
            case UserStatus of
                _ when is_atom(UserStatus); is_binary(UserStatus); is_list(UserStatus) ->
                    #{status => to_bin(UserStatus)};
                {Status, Info} when
                    (is_atom(Status) orelse is_list(Status) orelse is_binary(Status)) ->
                    #{status => to_bin(Status), info => to_bin(Info)};
                {{Status, _Sub}, _Info} when is_atom(Status) ->
                    #{status => to_bin(Status), info => to_bin(UserStatus)};
                #{status:=_Status} ->
                    UserStatus;
                _ ->
                    #{status => <<"unknown_error">>, info=>to_bin(UserStatus)}
            end
    end.


%% @doc Expands a server message like extended_status, but unknown errors are masked
-spec status(nkserver:id(), user_status()) ->
    expanded_status().

status(SrvId, UserStatus) ->
    case get_defined(SrvId, UserStatus) of
        {true, ExpandedStatus} ->
            ExpandedStatus;
        false ->
            case UserStatus of
                _ when is_atom(UserStatus); is_binary(UserStatus); is_list(UserStatus) ->
                    #{status => to_bin(UserStatus)};
                {Status, _} when
                    Status==badarg;
                    Status==badarith;
                    Status==function_clause;
                    Status==if_clause;
                    Status==undef;
                    Status==timeout_value;
                    Status==noproc;
                    Status==system_limit ->
                    status_internal(SrvId, UserStatus);
                {{Status, _}, _} when
                    Status==badmatch;
                    Status==case_clause;
                    Status==try_clause;
                    Status==badfun;
                    Status==badarity;
                    Status==nocatch ->
                    status_internal(SrvId, UserStatus);
                {Status, Info} when
                    (is_atom(Status) orelse is_list(Status) orelse is_binary(Status))
                    andalso (is_list(Info) orelse is_binary(Info))
                    andalso Status /= undef ->
                    #{status => to_bin(Status), info => to_bin(Info)};
                #{status:=_} ->
                    UserStatus;
                _ ->
                    #{info:=Info} = status_internal(SrvId, UserStatus),
                    case is_tuple(UserStatus) andalso size(UserStatus) > 0 andalso element(1, UserStatus) of
                        Status when is_atom(Status); is_binary(Status); is_list(Status) ->
                            #{status => to_bin(Status), info => Info};
                        _ ->
                            #{status => <<"unknown_error">>, info=>Info}
                    end
            end
    end.


%% @private
status_internal(SrvId, UserStatus) ->
    Ref = erlang:phash2(make_ref()) rem 10000,
    lager:notice("NkSERVER unknown internal status (~p): ~p (~p)", [Ref, UserStatus, SrvId]),
    Info = to_fmt("Internal reference (~p)", [Ref]),
    #{status => <<"unknown_error">>, info=>Info}.


%% @private
-spec get_defined(nkserver:id(), user_status()) ->
    {true, term(), term()} | false.

get_defined(SrvId, Single) when is_atom(Single); is_list(Single); is_binary(Single) ->
    call_defined(SrvId, Single, to_bin(Single));

get_defined(SrvId, Tuple) when is_tuple(Tuple), size(Tuple) > 0 ->
    call_defined(SrvId, Tuple, to_bin(element(1,Tuple)));

get_defined(_SrvId, _UserStatus) ->
    false.



%% @private
call_defined(SrvId, UserStatus, Status) ->
    case ?CALL_SRV(SrvId, status, [UserStatus]) of
        continue ->
            false;
        Info when is_list(Info) ->
            {true, #{status => Status, info => to_bin(Info)}};
        {Info, Vars} when is_list(Info), is_list(Vars) ->
            {true, #{status => Status, info => to_fmt(Info, Vars)}};
        Map when is_map(Map) ->
            {true, from_map(Map#{status => Status})};
        {Info, Map} when is_list(Info), is_map(Map) ->
            {true, from_map(Map#{status => Status, info => to_bin(Info)})};
        {Info, Vars, Map} when is_list(Info), is_list(Vars), is_map(Map) ->
            {true, from_map(Map#{status => Status, info => to_fmt(Info, Vars)})}
    end.


%% @private
from_map(Map) ->
    Syntax = #{
        status => binary,
        info => binary,
        code => integer,
        data => map
    },
    {ok, Parsed, []} = nklib_syntax:parse(Map, Syntax),
    case Parsed of
        #{data:=Data} ->
            Data2 = [{to_bin(K), to_bin(V)} || {K,V} <- maps:to_list(Data)],
            Parsed#{data:=maps:from_list(Data2)};
        _ ->
            Parsed
    end.


%% @private
to_fmt(Fmt, List) ->
    case catch io_lib:format(Fmt, List) of
        {'EXIT', _} ->
            lager:notice("Invalid format API reason: ~p, ~p", [Fmt, List]),
            <<>>;
        Val ->
            list_to_binary(Val)
    end.



%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).
