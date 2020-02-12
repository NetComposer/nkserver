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


%% @doc Basic tracing support
-module(nkserver_trace).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([new/2, new/3, new/4, update/1, parent/0]).
-export([error/1, tags/1, get_last_span/0]).
-export([trace/1, trace/2, trace/3]).
-export([event/1, event/2, log/2, log/3, log/4]).
-export([level_to_name/1, name_to_level/1, flatten_tags/1]).

-include("nkserver.hrl").
-include("nkserver_trace.hrl").


%% ===================================================================
%% Public
%% ===================================================================

-type span() :: term().
-type level() :: debug | info | notice | warning | error.
-type parent() :: term().
-type new_opts() ::
    #{
        parent => parent(),
        metadata => map()
    }.

%% @doc Starts a new span
-spec new(nkserver:id()|last, term()) ->
    any().

new(SrvId, SpanId) ->
    new(SrvId, SpanId, infinity).


%% @doc Starts a new span
-spec new(nkserver:id()|last, term(), fun()|infinity) ->
    any().

new(SrvId, SpanId, Fun) ->
    new(SrvId, SpanId, Fun, #{}).


%% @doc Starts a new span
%% By default, it only executes the fun, capturing exceptions
%% Additional init can be done in callback trace_new. You can, inside it:
%% - start a ot span
%% - push a span configuration calling span_push
-spec new(nkserver:id()|last, term(), fun()|infinity, new_opts()) ->
    any().

new(last, SpanId, Fun, Opts) ->
    case get_last_span() of
        {SrvId, _} when SrvId /= last ->
            new(SrvId, SpanId, Fun, Opts);
        _ when Fun == infinity ->
            ok;
        _ ->
            Fun()
    end;

new(SrvId, SpanId, Fun, Opts) ->
    case ?CALL_SRV(SrvId, trace_new, [SrvId, SpanId, Opts]) of
        {ok, Span} when Fun == infinity ->
            do_span_push(SrvId, Span),
            ok;
        {ok, Span} ->
            do_span_push(SrvId, Span),
            try
                Fun()
            catch
                Class:Reason:Stack ->
                    log(warning, "Trace exception '~s' (~p) (~p)", [Class, Reason, Stack]),
                    erlang:raise(Class, Reason, Stack)
            after
                _ = do_span_pop(),
                finish(SrvId, Span)
            end;
        {error, Error} ->
            {error, {trace_creation_error, Error}}
    end.


%% @doc Finishes a started trace. You don't need to call it directly
-spec finish(nkserver:id(), span()) ->
    any().

finish(SrvId, Span) ->
    ?CALL_SRV(SrvId, trace_finish, [Span]).


%% @doc Perform a number of updates operations on a span
-spec update(list()) ->
    ok.

update(Operations) ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_update, [Operations, Span])
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:update() ~p ~p (~p)", [Class, Reason, Stack])
            end;
        undefined ->
            ok
    end.



%% @doc Extract the parent of a span, to be used on a new one
-spec parent() ->
    parent() | undefined.

parent() ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_parent, [Span])
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:update() ~p ~p (~p)", [Class, Reason, Stack])
            end;
        undefined ->
            undefined
    end.


%% @doc Generates a new trace event
%% It calls callback trace_event.
%% By default, it will only log the event
-spec event(term()) ->
    any().

event(Type) ->
    event(Type, #{}).


%% @doc Generates a new trace event
%% It calls callback trace_event.
%% By default, it will only log the event
-spec event(term(), map()) ->
    ok.

event(Type, Meta) when is_map(Meta) ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_event, [Type, Meta, Span])
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:event() ~p ~p (~p)", [Class, Reason, Stack])
            end;
        undefined ->
            % Event without active span are printed as debug
            lager:debug("NkSERVER EVENT ~s (~p)", [Type, Meta])
    end.


%% @doc Generates a new trace entry
-spec trace(string()) ->
    any().

trace(Txt) when is_list(Txt) ->
    trace(Txt, [], #{}).


%% @doc Generates a new trace entry
-spec trace(string(), list()|map()) ->
    any().

trace(Txt, Args) when is_list(Txt), is_list(Args) ->
    trace(Txt, Args, #{});

trace(Txt, Meta) when is_list(Txt), is_map(Meta) ->
    trace(Txt, [], #{}).


%% @doc Generates a new trace entry
%% It calls callback trace_trace
%% By default, it will only trace the event
-spec trace(string(), list(), map()) ->
    any().

trace(Txt, Args, Meta) when is_list(Txt), is_list(Args), is_map(Meta) ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_trace, [Txt, Args, Meta, Span])
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:trace() ~p ~p (~p)", [Class, Reason, Stack])
            end,
            ok;
        undefined ->
            % Traces without active span are printed as debug
            lager:debug("NkSERVER TRACE "++Txt, Args)
    end.


%% @doc Generates a new log entry
-spec log(level(), string()) ->
    any().

log(Level, Txt) when is_atom(Level), is_list(Txt) ->
    log(Level, Txt, [], #{}).


%% @doc Generates a new log entry
-spec log(level(), string(), list()|map()) ->
    any().

log(Level, Txt, Args) when is_atom(Level), is_list(Txt), is_list(Args) ->
    log(Level, Txt, Args, #{});

log(Level, Txt, Meta) when is_atom(Level), is_list(Txt), is_map(Meta) ->
    log(Level, Txt, [], #{}).


%% @doc Generates a new log entry
%% It calls callback trace_log
%% By default, it will only log the event
-spec log(level(), string(), list(), map()) ->
    any().

log(Level, Txt, Args, Meta) when is_atom(Level), is_list(Txt), is_list(Args), is_map(Meta) ->
    case lists:member(Level, [debug, info, notice, warning, error]) of
        true ->
            case get_last_span() of
                {SrvId, Span} ->
                    try
                        ?CALL_SRV(SrvId, trace_log, [Level, Txt, Args, Meta, Span])
                    catch
                        Class:Reason:Stack ->
                            lager:warning("Exception calling nkserver_trace:log() ~p ~p (~p)", [Class, Reason, Stack])
                    end,
                    ok;
                undefined ->
                    % Logs without active span are printed with desired level
                    lager:log(Level, [], "NkSERVER LOG "++Txt, Args)
            end;
        false ->
            lager:error("Invalid log level: ~p", [Level])
    end.


%% @doc Mark an span as error
-spec error(nkserver:status()) ->
    any().

error(Error) ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_error, [Error, Span]),
                ok
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:span_error() ~p ~p (~p)", [Class, Reason, Stack])
            end;
        undefined ->
            ok
    end.


%% @doc Adds a number of tags to a trace
-spec tags(map()) ->
    any().

tags(Tags) ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_tags, [Tags, Span]),
                ok
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:log() ~p ~p (~p)", [Class, Reason, Stack])
            end;
        undefined ->
            ok
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


%% @doc
get_last_span() ->
    case erlang:get(nkserver_spans) of
        undefined -> undefined;
        [] -> undefined;
        [{SrvId, Span}|_] -> {SrvId, Span}
    end.


%% @doc Pushes a spain information to the process dictionary
%% nkserver is not going to use it by default, use it in your
%% trace_event and trace_log callbacks
do_span_push(SrvId, Span) ->
    Spans = case erlang:get(nkserver_spans) of
        undefined -> [];
        Spans0 -> Spans0
    end,
    erlang:put(nkserver_spans, [{SrvId, Span}|Spans]).


%% @doc
do_span_pop() ->
    case erlang:get(nkserver_spans) of
        [{SrvId, Span}|Spans] ->
            erlang:put(nkserver_spans, Spans),
            {SrvId, Span};
        _ ->
            undefined
    end.


%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).
