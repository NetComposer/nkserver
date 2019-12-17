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
-export([start/5, debug/2, debug/3, info/2, info/3, notice/2, notice/3, warning/2, warning/3]).
-export([trace/2, error/2, error/3, tags/2, status/3, log/3, log/4]).

-include("nkserver.hrl").
%% ===================================================================
%% Public
%% ===================================================================

-type run_opts() ::
#{
    base_audit => nkserver_audit:audit(),
    base_txt => string(),
    base_args => list
}.

-type level() :: debug | info | notice | warning | error.

-record(nkserver_trace, {
    srv :: nkserver:id(),
    trace :: binary(),
    has_ot :: boolean(),
    has_audit :: boolean(),
    base_txt :: string(),
    base_args :: list(),
    audit_srv :: nkserver:id() | undefined,
    base_audit :: nkserver_audit:audit() | undefined
}).




%%%% @doc
%%-spec run(nkserver:id(), term(), fun(), parent()) ->
%%    term().
%%
%%run(SrvId, Id, Fun, Parent) ->
%%    case ?CALL_SRV(SrvId, trace_create, [SrvId, Id, Parent]) of
%%        {ok, TraceId} ->
%%            Trace = {trace, SrvId, TraceId},
%%            try
%%                Fun(Trace)
%%            catch
%%                Class:Reason:Stack ->
%%                    Text = io_lib:format("Exception ~p: ~p (~p)", [Class, Reason, Stack]),
%%                    log(Trace, trace_exception, #{error => list_to_binary(Text)}),
%%                    erlang:raise(Class, Reason, Stack)
%%            after
%%                finish(Trace)
%%            end;
%%        {error, Error} ->
%%            {error, Error}
%%    end.
%%
%%
%%%% @doc Finishes a started trace. You don't need to call it directly
%%-spec finish(trace()) ->
%%    any().
%%
%%finish({trace, SrvId, TraceId}) ->
%%    ?CALL_SRV(SrvId, trace_finish, [SrvId, TraceId]).
%%
%%
%%%% @doc Generates a new trace entry
%%-spec log(trace(), term(), map()) ->
%%    any().
%%
%%log({trace, SrvId, TraceId}, Op, Opts) ->
%%    %lagger:error("DO LOG: ~p", [TraceId]),
%%    ?CALL_SRV(SrvId, trace_log, [SrvId, TraceId, Op, Opts]).
%%
%%
%%%% @doc Adds a number of tags to a trace
%%-spec tags(trace(), map()) ->
%%    any().
%%
%%tags({trace, SrvId, TraceId}, Tags) ->
%%    ?CALL_SRV(SrvId, trace_tags, [SrvId, TraceId, Tags]).
%%
%%
%%%% @doc Generates a new trace as child of an existing one
%%-spec make_parent(trace()) ->
%%    trace().
%%
%%make_parent({trace, SrvId, TraceId}) ->
%%    ?CALL_SRV(SrvId, trace_child, [SrvId, TraceId]).
%%
%%
%%default_create(_SrvId, Id) ->
%%    {default, Id}.
%%
%%default_finish(SrvId, Id) ->
%%    default_log(SrvId, Id, trace_finished, #{}).
%%
%%
%%default_log(SrvId, {default, Name}, Op, Opts) ->
%%    Msg = list_to_binary([
%%        Name,
%%        " (", nklib_util:to_binary(SrvId), "): ",
%%        nklib_util:to_binary(Op), " ",
%%
%%
%%
%%
%%    ])
%%"#{name} (#{SrvId}): #{op}" <>
%%case opts do
%%[] -> ""
%%_ -> " (#{inspect(opts)})"
%%end
%%
%%level = Keyword.get(opts, :level, :debug)
%%Logger.log(level, msg)
%%end
%%
%%def default_log(_SrvId, _id, _op, _opts), do: nil
%%end
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
%%
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


%% @doc
has_ot(SrvId) ->
    nkserver:get_cached_config(SrvId, nkserver_ot, activated) == true.


%% @doc
audit_srv(SrvId) ->
    nkserver:get_cached_config(SrvId, nkserver_audit, audit_srv).


-spec start(nkserver:id(), term(), string()|binary(), function(), run_opts()) ->
    any().

start(SrvId, SpanId, SpanName, Fun, Opts) ->
    Span = case has_ot(SrvId) of
        true ->
            nkserver_ot:new(SpanId, SrvId, SpanName);
        false ->
            undefined
    end,
    Trace = case Span of
        undefined ->
            nklib_util:luid();
        _ ->
            nkserver_ot:trace_id_hex(Span)
    end,
    Txt = maps:get(base_txt, Opts, "NkSERVER ") ++ "(trace:~s) ",
    Args = maps:get(base_args,  Opts, []) ++ [Trace],
    BaseAudit1 = maps:get(base_audit, Opts, #{}),
    BaseAudit2 = BaseAudit1#{app=>SrvId, trace=>Trace},
    AuditSrv = audit_srv(SrvId),
    Record = #nkserver_trace{
        srv = SrvId,
        trace = Trace,
        has_ot = Span /= undefined,
        has_audit = AuditSrv /= undefined,
        audit_srv = AuditSrv,
        base_txt = Txt,
        base_args = Args,
        base_audit = BaseAudit2
    },
    put({SpanId, nkserver_trace}, Record),
    try
        Fun()
    catch
        Class:Reason:Stack ->
            case Span of
                undefined ->
                    ok;
                _ ->
                    nkserver_ot:tag_error(SpanId, {Class, {Reason, Stack}})
            end,
            lager:warning("NkSERVER trace (~s) error ~p (~p, ~p)", [Trace, Class, Reason, Stack]),
            case Record of
                #nkserver_trace{has_audit=true, audit_srv=AuditSrv2, base_audit=BaseAudit2} ->
                    ExtStatus = nkserver_status:extended_status(SrvId, {Class, {Reason, Stack}}),
                    Audit = BaseAudit2#{
                        group => nkserver,
                        type => error,
                        id => maps:get(status, ExtStatus),
                        level => warning,
                        data => ExtStatus
                    },
                    nkserver_audit_sender:store(AuditSrv2, Audit);
                _ ->
                    ok
            end,
            erlang:raise(Class, Reason, Stack)
    after
        case Span of
            undefined -> ok;
            _ -> nkserver_ot:finish(SpanId)
        end
    end.


%% @doc See debug/3
-spec debug(any(), list()|binary()) ->
    ok.

debug(SpanId, Txt) ->
    debug(SpanId, Txt, []).


%% @doc Sends a debug message, only to lager and only if configured in service
-spec debug(any(), list()|binary(), list()) ->
    ok.

debug(SpanId, Txt, Args) ->
    TraceInfo = get({SpanId, nkserver_trace}),
    #nkserver_trace{
        srv = SrvId,
        base_txt = BaseTxt,
        base_args = BaseArgs
    } = TraceInfo,
    case nkserver:get_cached_config(SrvId, nkserver, debug) of
        true ->
            lager:log(debug, [], BaseTxt++Txt, BaseArgs++Args);
        false ->
            ok
    end.


%% @doc See log/4
-spec info(any(), list()|binary()) ->
    ok.

info(SpanId, Txt) ->
    info(SpanId, Txt, []).


%% @doc See log/4
-spec info(any(), list()|binary(), list()) ->
    ok.

info(SpanId, Txt, Args) ->
    log(SpanId, info, Txt, Args).


%% @doc See log/4
-spec notice(any(), list()|binary()) ->
    ok.

notice(SpanId, Txt) ->
    notice(SpanId, Txt, []).


%% @doc See log/4
-spec notice(any(), list()|binary(), list()) ->
    ok.

notice(SpanId, Txt, Args) ->
    log(SpanId, notice, Txt, Args).


%% @doc See log/4
-spec warning(any(), list()|binary()) ->
    ok.

warning(SpanId, Txt) ->
    warning(SpanId, Txt, []).


%% @doc See log/4
-spec warning(any(), list()|binary(), list()) ->
    ok.

warning(SpanId, Txt, Args) ->
    log(SpanId, warning, Txt, Args).


%% @doc See log/4
-spec error(any(), list()|binary()) ->
    ok.

error(SpanId, Txt) ->
    error(SpanId, Txt, []).


%% @doc See log/4
-spec error(any(), list()|binary(), list()) ->
    ok.

error(SpanId, Txt, Args) ->
    log(SpanId, error, Txt, Args).



%% @doc Sends an status message
%% - It is send to the span, expanded as extended_status
%% - It is printed in screen, expanded with extended_status
%% - It is sent to audit, group 'nkserver_error'
-spec status(any(), level(), nkserver:status()) ->
    ok.

status(SpanId, Level, Error) ->
    TraceInfo = get({SpanId, nkserver_trace}),
    #nkserver_trace{
        srv = SrvId,
        has_ot = HasOT,
        has_audit = HasAudit,
        base_txt = BaseTxt,
        base_args = BaseArgs,
        audit_srv = AuditSrv,
        base_audit = BaseAudit
    } = TraceInfo,
    case HasOT of
        true ->
            nkserver_ot:tag_error(SpanId, Error);
        false ->
            ok
    end,
    ExtStatus = #{status:=Status, info:=Info} = nkserver_status:extended_status(SrvId, Error),
    lager:log(Level, [], BaseTxt++"status ~s (~s)", BaseArgs++[Status, Info]),
    case HasAudit of
        true ->
            Audit2 = BaseAudit#{
                group => nkserver,
                type => error,
                level => Level,
                id => Status,
                msg => maps:get(info, ExtStatus)
            },
            nkserver_audit_sender:store(AuditSrv, Audit2);
        false ->
            ok
    end.


%% @doc Stores a number of tags
%% - Tags are added to span
%% - Tags are print to screen at level
%% - It is sent to audit, group nkserver_tags
-spec tags(any(), map()) ->
    ok.

tags(SpanId, Tags) ->
    TraceInfo = get({SpanId, nkserver_trace}),
    #nkserver_trace{
        has_ot = HasOT,
        has_audit = HasAudit,
        base_txt = BaseTxt,
        base_args = BaseArgs,
        audit_srv = AuditSrv,
        base_audit = BaseAudit
    } = TraceInfo,
    case HasOT of
        true ->
            nkserver_ot:tags(SpanId, Tags);
        false ->
            ok
    end,
    lager:log(info, [], BaseTxt++"tags ~p", BaseArgs++[Tags]),
    case HasAudit of
        true ->
            Audit2 = BaseAudit#{
                group => nkserver,
                type => tags,
                level => info,
                data => Tags
            },
            nkserver_audit_sender:store(AuditSrv, Audit2);
        false ->
            ok
    end.


%% @doc Sends a trace message
%% - It is send to the span as json
%% - It is printed in screen
%% - It is sent to audit, merging it
-spec trace(any(), nkserver_audit:audit()) ->
    ok.

trace(SpanId, Audit) ->
    TraceInfo = get({SpanId, nkserver_trace}),
    #nkserver_trace{
        has_ot = HasOT,
        has_audit = HasAudit,
        base_txt = BaseTxt,
        base_args = BaseArgs,
        audit_srv = AuditSrv,
        base_audit = BaseAudit
    } = TraceInfo,
    Audit2 = maps:merge(BaseAudit, Audit),
    {ok, [Audit3]} = nkserver_audit:parse(Audit2),
    Json = nklib_json:encode(Audit3),
    case HasOT of
        true ->
            nkserver_ot:log(SpanId, <<"audit_data: ", Json/binary>>);
        false ->
            ok
    end,
    lager:log(info, [], BaseTxt++"audit ~s", BaseArgs++[Json]),
    case HasAudit of
        true ->
            nkserver_audit_sender:do_store(AuditSrv, Audit3);
        false ->
            ok
    end.


%% @doc See log/4
-spec log(any(), level(), list()|binary()) ->
    ok.

log(SpanId, Level, Txt) ->
    log(SpanId, Level, Txt, []).


%% @doc Sends a log message
%% - It is send to the span
%% - It is printed in screen, with a level log
%% - It is sent to audit, group 'nkserver_log'
-spec log(any(), level(), list()|binary(), list()) ->
    ok.

log(SpanId, Level, Txt, Args) ->
    TraceInfo = get({SpanId, nkserver_trace}),
    #nkserver_trace{
        has_ot = HasOT,
        has_audit = HasAudit,
        base_txt = BaseTxt,
        base_args = BaseArgs,
        audit_srv = AuditSrv,
        base_audit = BaseAudit
    } = TraceInfo,
    case HasOT of
        true ->
            nkserver_ot:log(SpanId, Txt, Args);
        false ->
            ok
    end,
    lager:log(Level, [], BaseTxt++Txt, BaseArgs++Args),
    case HasAudit of
        true ->
            Audit = BaseAudit#{
                group => nkserver,
                type => log,
                level => Level,
                msg => list_to_binary(io_lib:format(Txt, Args))
            },
            nkserver_audit_sender:store(AuditSrv, Audit);
        false ->
            ok
    end.

