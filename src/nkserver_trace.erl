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
-export([new_span/2, new_span/3, new_span/4, finish_span/0, update_span/1, span_parent/0]).
-export([error/1, tags/1, get_last_span/0]).
-export([trace/1, trace/2, trace/3]).
-export([event/1, event/2, event/3, event/4, log/2, log/3, log/4, clean/1]).
-export([level_to_name/1, name_to_level/1, level_to_lager/1, flatten_tags/1]).
-export_type([level_name/0, level_num/0, span/0, parent/0]).

-include("nkserver.hrl").
-include("nkserver_trace.hrl").


%% ===================================================================
%% Public
%% ===================================================================

-type level_name() :: debug | trace | info | event | notice | warning | error.
-type level_num() :: 1..9.
-type span() :: #nkserver_span{}.

-type parent() :: term().
-type new_opts() :: map().

%% @doc Starts a new span
-spec new_span(nkserver:id()|last, term()) ->
    any().

new_span(SrvId, SpanId) ->
    new_span(SrvId, SpanId, infinity).


%% @doc Starts a new span
-spec new_span(nkserver:id()|last, term(), fun()|infinity) ->
    any().

new_span(SrvId, SpanId, Fun) ->
    new_span(SrvId, SpanId, Fun, #{}).


%% @doc Starts a new span
%% By default, it only executes the fun, capturing exceptions
%% Additional init can be done in callback trace_new_span. You can, inside it:
%% - start a ot span
%% - push a span configuration calling span_push
-spec new_span(nkserver:id()|last, term(), fun()|infinity, new_opts()) ->
    any().

new_span(last, SpanId, Fun, Opts) ->
    case get_last_span() of
        {SrvId, _} when SrvId /= last ->
            new_span(SrvId, SpanId, Fun, Opts);
        _ when Fun == infinity ->
            ok;
        _ ->
            Fun()
    end;

new_span(SrvId, SpanId, Fun, Opts) ->
    case ?CALL_SRV(SrvId, trace_new_span, [SrvId, SpanId, Opts]) of
        {ok, #nkserver_span{}=Span} when Fun == infinity ->
            do_span_push(SrvId, Span),
            ok;
        {ok, #nkserver_span{}=Span} ->
            do_span_push(SrvId, Span),
            try
                Fun()
            catch
                Class:Reason:Stack ->
                    log(warning, "Trace exception '~s' (~p) (~p)", [Class, Reason, Stack]),
                    erlang:raise(Class, Reason, Stack)
            after
                finish_span()
            end;
        {ok, SpanId2} ->

            nkserver_trace_lib:make_span(SpanId2, <<>>, [], #{});
        {error, Error} ->
            {error, {trace_creation_error, Error}}
    end.


%% @doc Finishes a started trace. You don't need to call it directly,
%% unless you start a 'infinity' span
-spec finish_span() ->
    any().

finish_span() ->
    {SrvId, Span} = do_span_pop(),
    ?CALL_SRV(SrvId, trace_finish_span, [Span]),
    ok.


%% @doc Perform a number of updates operations on a span
-spec update_span(list()) ->
    ok.

update_span(Operations) ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_update_span, [Operations, Span])
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:update() ~p ~p (~p)", [Class, Reason, Stack])
            end;
        undefined ->
            ok
    end.



%% @doc Extract the parent of a span, to be used on a new one
-spec span_parent() ->
    parent() | undefined.

span_parent() ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_span_parent, [Span])
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
    event(Type, [], [], Meta).



%% @doc Generates a new trace event
%% It calls callback trace_event.
%% By default, it will only log the event
-spec event(term(), list(), map()) ->
    ok.

event(Type, Txt, Meta) when is_map(Meta), is_list(Txt) ->
    event(Type, Txt, [], Meta).


%% @doc Generates a new trace event
%% It calls callback trace_event.
%% By default, it will only log the event
-spec event(term(), list(), list(), map()) ->
    ok.

event(Type, Txt, Args, Meta) when is_list(Txt), is_list(Args), is_map(Meta) ->
    case get_last_span() of
        {SrvId, Span} ->
            case has_level(?LEVEL_EVENT, Span) of
                true ->
                    try
                        ?CALL_SRV(SrvId, trace_event, [Type, Txt, Args, Meta, Span])
                    catch
                        Class:Reason:Stack ->
                            lager:warning("Exception calling nkserver_trace:event() ~p ~p (~p)", [Class, Reason, Stack])
                    end;
                false ->
                    ok
            end;
        undefined ->
            % Event without active span are printed as debug
            lager:debug("Trace EVENT ~s (~p)", [Type, Meta])
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
            case has_level(?LEVEL_TRACE, Span) of
                true ->
                    try
                        ?CALL_SRV(SrvId, trace_trace, [Txt, Args, Meta, Span])
                    catch
                        Class:Reason:Stack ->
                            lager:warning("Exception calling nkserver_trace:trace() ~p ~p (~p)", [Class, Reason, Stack])
                    end;
                false ->
                    ok
            end;
        undefined ->
            % Traces without active span are printed as debug
            lager:debug("TRACE "++Txt, Args)
    end.


%% @doc Generates a new log entry
-spec log(level_name(), string()) ->
    any().

log(Level, Txt) when is_atom(Level), is_list(Txt) ->
    log(Level, Txt, [], #{}).


%% @doc Generates a new log entry
-spec log(level_name(), string(), list()|map()) ->
    any().

log(Level, Txt, Args) when is_atom(Level), is_list(Txt), is_list(Args) ->
    log(Level, Txt, Args, #{});

log(Level, Txt, Meta) when is_atom(Level), is_list(Txt), is_map(Meta) ->
    log(Level, Txt, [], #{}).


%% @doc Generates a new log entry
%% It calls callback trace_log
%% By default, it will only log the event
-spec log(level_name(), string(), list(), map()) ->
    any().

log(Level, Txt, Args, Meta) when is_atom(Level), is_list(Txt), is_list(Args), is_map(Meta) ->
    case lists:member(Level, [debug, info, notice, warning, error]) of
        true ->
            case get_last_span() of
                {SrvId, Span} ->
                    Level2 = name_to_level(Level),
                    case has_level(Level2, Span) of
                        true ->
                            try
                                ?CALL_SRV(SrvId, trace_log, [Level2, Txt, Args, Meta, Span])
                            catch
                                Class:Reason:Stack ->
                                    lager:warning("Exception calling nkserver_trace:log() ~p ~p (~p)", [Class, Reason, Stack])
                            end;
                        false ->
                            ok
                    end;
                undefined ->
                    % Logs without active span are printed with desired level
                    lager:log(Level, [], "Trace LOG "++Txt, Args)
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
            lager:notice("Trace ERROR: ~p", [Error])
    end.


%% @doc Adds a number of tags to a trace
-spec tags(map()) ->
    any().

tags(Tags) ->
    case get_last_span() of
        {SrvId, Span} ->
            case has_level(?LEVEL_TRACE, Span) of
                true ->
                    try
                        ?CALL_SRV(SrvId, trace_tags, [Tags, Span]),
                        ok
                    catch
                        Class:Reason:Stack ->
                            lager:warning("Exception calling nkserver_trace:log() ~p ~p (~p)", [Class, Reason, Stack])
                    end;
                false ->
                    ok
            end;
        undefined ->
            lager:debug("Trace TAGS: ~p", [Tags])
    end.


%% @doc Cleans a message before tracing (to remove passwords, etc.)
-spec clean(any()) ->
    any().

clean(Msg) ->
    case get_last_span() of
        {SrvId, Span} ->
            try
                ?CALL_SRV(SrvId, trace_clean, [Msg, Span])
            catch
                Class:Reason:Stack ->
                    lager:warning("Exception calling nkserver_trace:clean() ~p ~p (~p)", [Class, Reason, Stack])
            end;
        undefined ->
            Msg
    end.


%% @doc
level_to_name(?LEVEL_DEBUG) -> debug;
level_to_name(?LEVEL_TRACE) -> trace;
level_to_name(?LEVEL_INFO) -> info;
level_to_name(?LEVEL_EVENT) -> event;
level_to_name(?LEVEL_NOTICE) -> notice;
level_to_name(?LEVEL_WARNING) -> warning;
level_to_name(?LEVEL_ERROR) -> error;
level_to_name(?LEVEL_OFF) -> off.


%% @doc
name_to_level(debug) -> ?LEVEL_DEBUG;
name_to_level(trace) -> ?LEVEL_TRACE;
name_to_level(info) -> ?LEVEL_INFO;
name_to_level(event) -> ?LEVEL_EVENT;
name_to_level(notice) -> ?LEVEL_NOTICE;
name_to_level(warning) -> ?LEVEL_WARNING;
name_to_level(error) -> ?LEVEL_ERROR;
name_to_level(off) -> ?LEVEL_OFF;
name_to_level(LevelNum) when is_integer(LevelNum), LevelNum>0, LevelNum<10 -> LevelNum.


%% @doc
level_to_lager(?LEVEL_DEBUG) -> debug;
level_to_lager(?LEVEL_TRACE) -> debug;
level_to_lager(?LEVEL_INFO) -> info;
level_to_lager(?LEVEL_EVENT) -> info;
level_to_lager(?LEVEL_NOTICE) -> notice;
level_to_lager(?LEVEL_WARNING) -> warning;
level_to_lager(?LEVEL_ERROR) -> error.


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
has_level(Level, #nkserver_span{levels=Levels}) ->
    do_has_level(Levels, Level).

do_has_level([], _Level) -> false;
do_has_level([{_, L}|_], Level) when L >= Level -> true;
do_has_level([_|Rest], Level) -> do_has_level(Rest, Level).


%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).
