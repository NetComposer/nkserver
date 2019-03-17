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

-module(nkserver_span).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([start_root/2, start_child/3, start_shared_child/2, finish/0, finish_shared/0]).
-export([tag/1, tag/2, log/1, ids/0]).
-compile(inline).


-include("nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================



%% ===================================================================
%% Public
%% ===================================================================

start_root(SrvId, Name) ->
    ottersp:start(Name),
    tag(nkserver, SrvId).


start_child(SrvId, Name, undefined) ->
    start_child(SrvId, Name, {undefined, undefined});

start_child(SrvId, Name, {TraceId, ParentId}) ->
    ottersp:start(Name, TraceId, ParentId),
    tag(nkserver, SrvId).


start_shared_child(SrvId, Name) ->
    case ids() of
        undefined ->
            error(no_root_span);
        {TraceId, ParentId} ->
            ottersp:push(),
            start_child(SrvId, Name, {TraceId, ParentId})
    end.


tag(Key, Val) ->
    ottersp:tag(Key, Val).


tag(Tags) ->
    lists:foreach(
        fun({Key, Val}) -> ottersp:tag(Key, Val) end,
        maps:to_list(Tags)).


log(Val) ->
    ottersp:log(Val).


ids() ->
    case ottersp:ids() of
        undefined ->
            {undefined, undefined};
        {TraceId, ParentId} ->
            {TraceId, ParentId}
    end.


finish() ->
    ottersp:finish().


finish_shared() ->
    finish(),
    ottersp:pop().


%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).



