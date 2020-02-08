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
-export([trace_run/4, event/3, event/4, log/4, log/5, log/6, trace_tags/3]).
-export([level_to_name/1, name_to_level/1, flatten_tags/1]).

%%-export([start/5, debug/2, debug/3, info/2, info/3, notice/2, notice/3, warning/2, warning/3]).
%%-export([trace/2, error/2, error/3, tags/2, status/3, log/3, log/4]).

-include("nkserver.hrl").
%% ===================================================================
%% Public
%% ===================================================================




-type id() :: term().
-type trace_id() :: term().
-type event_type() :: atom().
-type run_opts() ::
    #{
        name => binary(),           % Name for trace
        data => data(),             % Common data
        metadata => metadata()      % Common metadata
    }.

% To be merged with each call
-type data() :: map().

% To be used at each call
-type metadata() :: map().

-type level() :: debug | info | notice | warning | error.



%% @doc
-spec trace_run(nkserver:id(), term(), fun(), run_opts()) ->
    any().

trace_run(SrvId, TraceId, Fun, Opts) ->
    case ?CALL_SRV(SrvId, trace_create, [SrvId, TraceId, Opts]) of
        {ok, TraceId2} ->
            try
                Fun(TraceId2)
            catch
                Class:Reason:Stack ->
                    Data = #{
                        class => Class,
                        reason => nklib_util:to_binary(Reason),
                        stack => nklib_util:to_binary(Stack)
                    },
                    log(SrvId, TraceId2, warning, trace_exception, Data),
                    erlang:raise(Class, Reason, Stack)
            after
                trace_finish(SrvId, TraceId2)
            end;
        {error, Error} ->
            {error, {trace_creation_error, Error}}
    end.


%% @doc Finishes a started trace. You don't need to call it directly
-spec trace_finish(nkserver:id(), trace_id()) ->
    any().

trace_finish(SrvId, TraceId) ->
    ?CALL_SRV(SrvId, trace_finish, [SrvId, TraceId]).


%% @doc Generates a new trace event
-spec event(nkserver:id(), trace_id(), event_type()) ->
    any().

event(SrvId, TraceId, Type) ->
    event(SrvId, TraceId, Type, #{}).


%% @doc Generates a new trace event
%% Log should never cause an exception
-spec event(nkserver:id(), trace_id(), event_type(), metadata()) ->
    ok.

event(SrvId, TraceId, Type, Data) when is_map(Data) ->
    try
        ?CALL_SRV(SrvId, trace_event, [SrvId, TraceId, Type, Data])
    catch
        Class:Reason:Stack ->
            lager:warning("Exception calling nkserver_trace:event() ~p ~p (~p)", [Class, Reason, Stack])
    end.


%% @doc Generates a new log entry
-spec log(nkserver:id(), trace_id(), level(), string()) ->
    any().

log(SrvId, Trace, Level, Txt) when is_atom(Level), is_list(Txt) ->
    log(SrvId, Trace, Level, Txt, [], #{}).


%% @doc Generates a new log entry
-spec log(nkserver:id(), trace_id(), level(), string(), list()|map()) ->
    any().

log(SrvId, Trace, Level, Txt, Args) when is_atom(Level), is_list(Txt), is_list(Args) ->
    log(SrvId, Trace, Level, Txt, Args, #{});

log(SrvId, Trace, Level, Txt, Data) when is_atom(Level), is_list(Txt), is_map(Data) ->
    log(SrvId, Trace, Level, Txt, [], #{}).


%% @doc Generates a new trace entry
%% Log should never cause an exception
-spec log(nkserver:id(), trace_id(), level(), string(), list(), metadata()) ->
    any().

log(SrvId, TraceId, Level, Txt, Args, Data)
        when is_atom(Level), is_list(Txt), is_list(Args), is_map(Data) ->
    try
        ?CALL_SRV(SrvId, trace_log, [SrvId, TraceId, Level, Txt, Args, Data])
    catch
        Class:Reason:Stack ->
            lager:warning("Exception calling nkserver_trace:log() ~p ~p (~p)", [Class, Reason, Stack])
    end.


%% @doc Adds a number of tags to a trace
-spec trace_tags(nkserver:id(), trace_id(), map()) ->
    any().

trace_tags(SrvId, TraceId, Tags) ->
    try
        ?CALL_SRV(SrvId, trace_tags, [SrvId, TraceId, Tags])
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
    do_flatten_tags(maps:to_list(Map), <<>>, []).


do_flatten_tags([], _Prefix, Acc) ->
    maps:from_list(Acc);

do_flatten_tags([{Key, Val}|Rest], Prefix, Acc) ->
    Key2 = case Prefix of
        <<>> ->
            to_bin(Key);
        _ ->
            <<Prefix/binary, $., (to_bin(Key))/binary>>
    end,
    case is_map(Val) of
        true ->
            do_flatten_tags(maps:to_list(Val), Key2, Acc);
        false ->
            do_flatten_tags(Rest, Prefix, [{Key2, to_bin(Val)}|Acc])
    end.



to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).


%%%% @doc Generates a new trace as child of an existing one
%%-spec make_parent(trace()) ->
%%    trace().
%%
%%make_parent({trace, SrvId, TraceId}) ->
%%    ?CALL_SRV(SrvId, trace_child, [SrvId, TraceId]).
%%
%%



%% @doc Runs a function into a traced environment
%% - SrvId is used to find if audit_srv key if present
%% - SpanId is used to refer to the span in all functions
%% - SpanName is used to create the span
%% - If the process fails:
%%      - An error in inserted in span, and it is finished
%%      - A lager:warning is presented
%%      - An audit with group 'nkserver_error' is generated, level warning
%% - During process, can call log/4, error/3 and tags/3


%%%% @doc
%%has_ot(SrvId) ->
%%    nkserver:get_cached_config(SrvId, nkserver_ot, activated) == true.
%%
%%
%%%% @doc
%%audit_srv(SrvId) ->
%%    nkserver:get_cached_config(SrvId, nkserver_audit, audit_srv).
%%
%%
%%-spec start(nkserver:id(), term(), string()|binary(), function(), run_opts()) ->
%%    any().
%%
%%start(SrvId, SpanId, SpanName, Fun, Opts) ->
%%    Span = case has_ot(SrvId) of
%%        true ->
%%            nkserver_ot:new(SpanId, SrvId, SpanName);
%%        false ->
%%            undefined
%%    end,
%%    Trace = case Span of
%%        undefined ->
%%            nklib_util:luid();
%%        _ ->
%%            nkserver_ot:trace_id_hex(Span)
%%    end,
%%    Txt = maps:get(base_txt, Opts, "NkSERVER ") ++ "(trace:~s) ",
%%    Args = maps:get(base_args,  Opts, []) ++ [Trace],
%%    BaseAudit1 = maps:get(base_audit, Opts, #{}),
%%    BaseAudit2 = BaseAudit1#{app=>SrvId, trace=>Trace},
%%    AuditSrv = audit_srv(SrvId),
%%    Record = #nkserver_trace{
%%        srv = SrvId,
%%        trace = Trace,
%%        has_ot = Span /= undefined,
%%        has_audit = AuditSrv /= undefined,
%%        audit_srv = AuditSrv,
%%        base_txt = Txt,
%%        base_args = Args,
%%        base_audit = BaseAudit2
%%    },
%%    put({SpanId, nkserver_trace}, Record),
%%    try
%%        Fun()
%%    catch
%%        Class:Reason:Stack ->
%%            case Span of
%%                undefined ->
%%                    ok;
%%                _ ->
%%                    nkserver_ot:tag_error(SpanId, {Class, {Reason, Stack}})
%%            end,
%%            lager:warning("NkSERVER trace (~s) error ~p (~p, ~p)", [Trace, Class, Reason, Stack]),
%%            case Record of
%%                #nkserver_trace{has_audit=true, audit_srv=AuditSrv2, base_audit=BaseAudit2} ->
%%                    ExtStatus = nkserver_status:extended_status(SrvId, {Class, {Reason, Stack}}),
%%                    Audit = BaseAudit2#{
%%                        group => nkserver,
%%                        type => error,
%%                        id => maps:get(status, ExtStatus),
%%                        level => warning,
%%                        data => ExtStatus
%%                    },
%%                    nkserver_audit_sender:store(AuditSrv2, Audit);
%%                _ ->
%%                    ok
%%            end,
%%            erlang:raise(Class, Reason, Stack)
%%    after
%%        case Span of
%%            undefined -> ok;
%%            _ -> nkserver_ot:finish(SpanId)
%%        end
%%    end.
%%
%%
%%%% @doc See debug/3
%%-spec debug(any(), list()|binary()) ->
%%    ok.
%%
%%debug(SpanId, Txt) ->
%%    debug(SpanId, Txt, []).
%%
%%
%%%% @doc Sends a debug message, only to lager and only if configured in service
%%-spec debug(any(), list()|binary(), list()) ->
%%    ok.
%%
%%debug(SpanId, Txt, Args) ->
%%    TraceInfo = get({SpanId, nkserver_trace}),
%%    #nkserver_trace{
%%        srv = SrvId,
%%        base_txt = BaseTxt,
%%        base_args = BaseArgs
%%    } = TraceInfo,
%%    case nkserver:get_cached_config(SrvId, nkserver, debug) of
%%        true ->
%%            lager:log(debug, [], BaseTxt++Txt, BaseArgs++Args);
%%        false ->
%%            ok
%%    end.
%%
%%
%%%% @doc See log/4
%%-spec info(any(), list()|binary()) ->
%%    ok.
%%
%%info(SpanId, Txt) ->
%%    info(SpanId, Txt, []).
%%
%%
%%%% @doc See log/4
%%-spec info(any(), list()|binary(), list()) ->
%%    ok.
%%
%%info(SpanId, Txt, Args) ->
%%    log(SpanId, info, Txt, Args).
%%
%%
%%%% @doc See log/4
%%-spec notice(any(), list()|binary()) ->
%%    ok.
%%
%%notice(SpanId, Txt) ->
%%    notice(SpanId, Txt, []).
%%
%%
%%%% @doc See log/4
%%-spec notice(any(), list()|binary(), list()) ->
%%    ok.
%%
%%notice(SpanId, Txt, Args) ->
%%    log(SpanId, notice, Txt, Args).
%%
%%
%%%% @doc See log/4
%%-spec warning(any(), list()|binary()) ->
%%    ok.
%%
%%warning(SpanId, Txt) ->
%%    warning(SpanId, Txt, []).
%%
%%
%%%% @doc See log/4
%%-spec warning(any(), list()|binary(), list()) ->
%%    ok.
%%
%%warning(SpanId, Txt, Args) ->
%%    log(SpanId, warning, Txt, Args).
%%
%%
%%%% @doc See log/4
%%-spec error(any(), list()|binary()) ->
%%    ok.
%%
%%error(SpanId, Txt) ->
%%    error(SpanId, Txt, []).
%%
%%
%%%% @doc See log/4
%%-spec error(any(), list()|binary(), list()) ->
%%    ok.
%%
%%error(SpanId, Txt, Args) ->
%%    log(SpanId, error, Txt, Args).
%%
%%
%%
%%%% @doc Sends an status message
%%%% - It is send to the span, expanded as extended_status
%%%% - It is printed in screen, expanded with extended_status
%%%% - It is sent to audit, group 'nkserver_error'
%%-spec status(any(), level(), nkserver:status()) ->
%%    ok.
%%
%%status(SpanId, Level, Error) ->
%%    TraceInfo = get({SpanId, nkserver_trace}),
%%    #nkserver_trace{
%%        srv = SrvId,
%%        has_ot = HasOT,
%%        has_audit = HasAudit,
%%        base_txt = BaseTxt,
%%        base_args = BaseArgs,
%%        audit_srv = AuditSrv,
%%        base_audit = BaseAudit
%%    } = TraceInfo,
%%    case HasOT of
%%        true ->
%%            nkserver_ot:tag_error(SpanId, Error);
%%        false ->
%%            ok
%%    end,
%%    ExtStatus = #{status:=Status, info:=Info} = nkserver_status:extended_status(SrvId, Error),
%%    lager:log(Level, [], BaseTxt++"status ~s (~s)", BaseArgs++[Status, Info]),
%%    case HasAudit of
%%        true ->
%%            Audit2 = BaseAudit#{
%%                group => nkserver,
%%                type => error,
%%                level => Level,
%%                id => Status,
%%                msg => maps:get(info, ExtStatus)
%%            },
%%            nkserver_audit_sender:store(AuditSrv, Audit2);
%%        false ->
%%            ok
%%    end.
%%
%%
%%%% @doc Stores a number of tags
%%%% - Tags are added to span
%%%% - Tags are print to screen at level
%%%% - It is sent to audit, group nkserver_tags
%%-spec tags(any(), map()) ->
%%    ok.
%%
%%tags(SpanId, Tags) ->
%%    TraceInfo = get({SpanId, nkserver_trace}),
%%    #nkserver_trace{
%%        has_ot = HasOT,
%%        has_audit = HasAudit,
%%        base_txt = BaseTxt,
%%        base_args = BaseArgs,
%%        audit_srv = AuditSrv,
%%        base_audit = BaseAudit
%%    } = TraceInfo,
%%    case HasOT of
%%        true ->
%%            nkserver_ot:tags(SpanId, Tags);
%%        false ->
%%            ok
%%    end,
%%    lager:log(info, [], BaseTxt++"tags ~p", BaseArgs++[Tags]),
%%    case HasAudit of
%%        true ->
%%            Audit2 = BaseAudit#{
%%                group => nkserver,
%%                type => tags,
%%                level => info,
%%                data => Tags
%%            },
%%            nkserver_audit_sender:store(AuditSrv, Audit2);
%%        false ->
%%            ok
%%    end.
%%
%%
%%%% @doc Sends a trace message
%%%% - It is send to the span as json
%%%% - It is printed in screen
%%%% - It is sent to audit, merging it
%%-spec trace(any(), nkserver_audit:audit()) ->
%%    ok.
%%
%%trace(SpanId, Audit) ->
%%    TraceInfo = get({SpanId, nkserver_trace}),
%%    #nkserver_trace{
%%        has_ot = HasOT,
%%        has_audit = HasAudit,
%%        base_txt = BaseTxt,
%%        base_args = BaseArgs,
%%        audit_srv = AuditSrv,
%%        base_audit = BaseAudit
%%    } = TraceInfo,
%%    Audit2 = maps:merge(BaseAudit, Audit),
%%    {ok, [Audit3]} = nkserver_audit:parse(Audit2),
%%    Json = nklib_json:encode(Audit3),
%%    case HasOT of
%%        true ->
%%            nkserver_ot:log(SpanId, <<"audit_data: ", Json/binary>>);
%%        false ->
%%            ok
%%    end,
%%    lager:log(info, [], BaseTxt++"audit ~s", BaseArgs++[Json]),
%%    case HasAudit of
%%        true ->
%%            nkserver_audit_sender:do_store(AuditSrv, Audit3);
%%        false ->
%%            ok
%%    end.
%%
%%
%%%% @doc See log/4
%%-spec log(any(), level(), list()|binary()) ->
%%    ok.
%%
%%log(SpanId, Level, Txt) ->
%%    log(SpanId, Level, Txt, []).
%%
%%
%%%% @doc Sends a log message
%%%% - It is send to the span
%%%% - It is printed in screen, with a level log
%%%% - It is sent to audit, group 'nkserver_log'
%%-spec log(any(), level(), list()|binary(), list()) ->
%%    ok.
%%
%%log(SpanId, Level, Txt, Args) ->
%%    TraceInfo = get({SpanId, nkserver_trace}),
%%    #nkserver_trace{
%%        has_ot = HasOT,
%%        has_audit = HasAudit,
%%        base_txt = BaseTxt,
%%        base_args = BaseArgs,
%%        audit_srv = AuditSrv,
%%        base_audit = BaseAudit
%%    } = TraceInfo,
%%    case HasOT of
%%        true ->
%%            nkserver_ot:log(SpanId, Txt, Args);
%%        false ->
%%            ok
%%    end,
%%    lager:log(Level, [], BaseTxt++Txt, BaseArgs++Args),
%%    case HasAudit of
%%        true ->
%%            Audit = BaseAudit#{
%%                group => nkserver,
%%                type => log,
%%                level => Level,
%%                msg => list_to_binary(io_lib:format(Txt, Args))
%%            },
%%            nkserver_audit_sender:store(AuditSrv, Audit);
%%        false ->
%%            ok
%%    end.

