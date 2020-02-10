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


%% @doc These functions are useful if nkserver_ot and nkserver_audit are installed

-module(nkserver_trace).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([span_run/4, span_push/1, span_pop/0, span_peak/0]).
-export([event/3, event/4, log/4, log/5, log/6, tags/3]).
-export([level_to_name/1, name_to_level/1, flatten_tags/1]).

%%-export([start/5, debug/2, debug/3, info/2, info/3, notice/2, notice/3, warning/2, warning/3]).
%%-export([trace/2, error/2, error/3, tags/2, status/3, log/3, log/4]).

-include("nkserver.hrl").
-include("nkserver_trace.hrl").


%% ===================================================================
%% Public
%% ===================================================================

-type span() :: term().
-type level() :: debug | info | notice | warning | error.



%% @doc
-spec span_run(nkserver:id(), term(), fun(), any()) ->
    any().

span_run(SrvId, SpanId, Fun, Opts) ->
    case ?CALL_SRV(SrvId, span_create, [SrvId, SpanId, Opts]) of
        {ok, Span} ->
            try
                Fun()
            catch
                Class:Reason:Stack ->
                    Data = #{
                        class => Class,
                        reason => nklib_util:to_binary(Reason),
                        stack => nklib_util:to_binary(Stack)
                    },
                    log(SrvId, Span, warning, trace_exception, Data),
                    erlang:raise(Class, Reason, Stack)
            after
                span_finish(SrvId, Span)
            end;
        {error, Error} ->
            {error, {trace_creation_error, Error}}
    end.


%% @doc Finishes a started trace. You don't need to call it directly
-spec span_finish(nkserver:id(), span()) ->
    any().

span_finish(SrvId, Span) ->
    ?CALL_SRV(SrvId, span_finish, [SrvId, Span]).


%% @doc
span_push(Span) ->
    Spans = case erlang:get(nkserver_spans) of
        undefined -> [];
        Spans0 -> Spans0
    end,
    erlang:put(nkserver_spans, [Span|Spans]).


%% @doc
span_pop() ->
    case erlang:get(nkserver_spans) of
        [Span|Spans] ->
            erlang:put(nkserver_spans, Spans),
            Span;
        _ ->
            undefined
    end.


%% @doc
span_peak() ->
    case erlang:get(nkserver_spans) of
        undefined -> undefined;
        [Span|_] -> Span
    end.


%% @doc Generates a new trace event
-spec event(nkserver:id(), term(), term()) ->
    any().

event(SrvId, Group, Type) ->
    event(SrvId, Group, Type, #{}).


%% @doc Generates a new trace event
%% Log should never cause an exception
-spec event(nkserver:id(), term(), term(), map()) ->
    ok.

event(SrvId, Group, Type, Data) when is_map(Data) ->
    try
        ?CALL_SRV(SrvId, trace_event, [SrvId, Group, Type, Data])
    catch
        Class:Reason:Stack ->
            lager:warning("Exception calling nkserver_trace:event() ~p ~p (~p)", [Class, Reason, Stack])
    end.


%% @doc Generates a new log entry
-spec log(nkserver:id(), term(), level(), string()) ->
    any().

log(SrvId, Group, Level, Txt) when is_atom(Level), is_list(Txt) ->
    log(SrvId, Group, Level, Txt, [], #{}).


%% @doc Generates a new log entry
-spec log(nkserver:id(), term(), level(), string(), list()|map()) ->
    any().

log(SrvId, Group, Level, Txt, Args) when is_atom(Level), is_list(Txt), is_list(Args) ->
    log(SrvId, Group, Level, Txt, Args, #{});

log(SrvId, Group, Level, Txt, Data) when is_atom(Level), is_list(Txt), is_map(Data) ->
    log(SrvId, Group, Level, Txt, [], #{}).


%% @doc Generates a new trace entry
%% Log should never cause an exception
-spec log(nkserver:id(), term(), level(), string(), list(), map()) ->
    any().

log(SrvId, Group, Level, Txt, Args, Data)
        when is_atom(Level), is_list(Txt), is_list(Args), is_map(Data) ->
    try
        ?CALL_SRV(SrvId, trace_log, [SrvId, Group, Level, Txt, Args, Data])
    catch
        Class:Reason:Stack ->
            lager:warning("Exception calling nkserver_trace:log() ~p ~p (~p)", [Class, Reason, Stack])
    end.


%% @doc Adds a number of tags to a trace
-spec tags(nkserver:id(), term(), map()) ->
    any().

tags(SrvId, Group, Tags) ->
    try
        ?CALL_SRV(SrvId, trace_tags, [SrvId, Group, Tags])
    catch
        Class:Reason:Stack ->
            lager:warning("Exception calling nkserver_trace:log() ~p ~p (~p)", [Class, Reason, Stack])
    end.



%% @doc
level_to_name(1) -> debug;
level_to_name(2) -> info;
level_to_name(3) -> notice;
level_to_name(4) -> warning;
level_to_name(5) -> error;
level_to_name(debug) -> debug;
level_to_name(info) -> info;
level_to_name(notice) -> notice;
level_to_name(warning) -> warning;
level_to_name(error) -> error;
level_to_name(_) -> error.


%% @doc
name_to_level(1) -> 1;
name_to_level(2) -> 2;
name_to_level(3) -> 3;
name_to_level(4) -> 4;
name_to_level(5) -> 5;
name_to_level(debug) -> 1;
name_to_level(info) -> 2;
name_to_level(notice) -> 3;
name_to_level(warning) -> 4;
name_to_level(error) -> 5.


%% @doc
flatten_tags(Map) ->
    maps:from_list(do_flatten_tags(maps:to_list(Map), <<>>, [])).


do_flatten_tags([], _Prefix, Acc) ->
    Acc;

do_flatten_tags([{Key, Val}|Rest], Prefix, Acc) ->
    Key2 = case Prefix of
        <<>> ->
            to_bin(Key);
        _ ->
            <<Prefix/binary, $., (to_bin(Key))/binary>>
    end,
    Acc2 = if
        is_map(Val) ->
            do_flatten_tags(maps:to_list(Val), Key2, Acc);
        is_list(Val), is_binary(hd(Val)) ->
            Val2 = nklib_util:bjoin([to_bin(V) || V<-Val], $,),
            [{Key2, Val2}|Acc];
        true ->
            [{Key2, to_bin(Val)}|Acc]
    end,
    do_flatten_tags(Rest, Prefix, Acc2).


%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).
