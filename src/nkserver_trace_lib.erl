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

%% @doc
-module(nkserver_trace_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([make_span/4]).
-export([new/3, finish/1, update/2, parent/1]).
-export([log/5, event/5, trace/4, tags/2, error/2]).
-include_lib("nkactor/include/nkactor.hrl").
-include_lib("nkserver_trace.hrl").

%% @doc
make_span(SpanId, Name, Levels, Meta) when is_list(Levels) ->
    Levels2 = [{Type, nkserver_trace:name_to_level(Level)} || {Type, Level} <- Levels],
    #nkserver_span{
        id = SpanId,
        name = Name,
        levels = Levels2,
        meta = Meta
    }.


%% @doc
new(SrvId, Span, Opts) ->
    #nkserver_span{id=SpanId, name=Name, meta=Meta} = Span,
    Meta2 = case trace_level(Span) < ?LEVEL_OFF of
        true ->
            TraceParent = case Opts of
                #{parent:=OptsParent} when OptsParent/=undefined ->
                    OptsParent;
                #{parent:=none} ->
                    undefined;
                _ ->
                    case nkserver_trace:get_last_span() of
                        {_, #nkserver_span{id=ParentName}} ->
                            nkserver_ot:make_parent(ParentName);
                        _ ->
                            undefined
                    end
            end,

            nkserver_ot:new(SpanId, SrvId, Name, TraceParent),
            App = maps:get(app, Meta, SrvId),
            nkserver_ot:update(SpanId, [{app, App}]),
            Tags = nkserver_trace:flatten_tags(Meta),
            TraceHex = nkserver_ot:trace_id_hex(SpanId),
            % Connect to http://127.0.0.1:16686/trace/TraceHex
            SpanHex = nkserver_ot:span_id_hex(SpanId),
            % http://127.0.0.1:16686/trace/TraceHexuiFind=SpanHex
            nkserver_ot:tags(SpanId, Tags),
            Meta#{
                trace_id => TraceHex,
                span_id => SpanHex,
                span_name => Name,
                target => maps:get(target, Meta, Name)
            };
        false ->
            Meta
    end,
    Span2 = Span#nkserver_span{meta = Meta2},
    trace("span started", [], #{}, Span2),
    {ok, Span2}.


%% @doc Called from callbacks
finish(#nkserver_span{id=Id}=Span) ->
    case trace_level(Span) > ?LEVEL_OFF of
        true ->
            nkserver_ot:finish(Id);
        false ->
            ok
    end,
    trace("span finished", [], #{}, Span);

finish(_Span) ->
    continue.


%% @doc
update(Updates, #nkserver_span{id=Id}=Span) ->
    case trace_level(Span) < ?LEVEL_OFF of
        true ->
            nkserver_ot:update(Id, Updates);
        false ->
            ok
    end;

update(_Updates, _Span) ->
    continue.


%% @doc
parent(#nkserver_span{id=Id}=Span) ->
    case trace_level(Span) < ?LEVEL_OFF of
        true ->
            nkserver_ot:make_parent(Id);
        false ->
            ok
    end;

parent(_Span) ->
    continue.


%% @doc
event(EvType, Txt, Args, Data, #nkserver_span{}=Span) ->
    do_trace(?LEVEL_EVENT, EvType, Txt, Args, Data, Span);

event(_EvType, _Txt, _Args, _Data, _Span) ->
    continue.


%% @doc
trace(Txt, Args, Data, #nkserver_span{}=Span) ->
    do_trace(?LEVEL_TRACE, trace, Txt, Args, Data, Span);

trace(_Txt, _Args, _Data, _Span) ->
    continue.


%% @doc
log(LevelName, Txt, Args, Data, #nkserver_span{}=Span) ->
    Level = nkserver_trace:name_to_level(LevelName),
    do_trace(Level, LevelName, Txt, Args, Data, Span);

log(_LevelName, _Txt, _Args, _Data, _Span) ->
    continue.


%% @doc
tags(Tags, #nkserver_span{id=Id}=Span) ->
    case trace_level(Span) < ?LEVEL_OFF of
        true ->
            nkserver_ot:tags(Id, Tags);
        false ->
            ok
    end,
    do_trace(?LEVEL_EVENT, tags, [], [], Tags, Span);

tags(_Tags, _Span) ->
    continue.


%% @doc Called from callbacks
error(Error, #nkserver_span{id=Id}=Span) ->
    case trace_level(Span) < ?LEVEL_OFF of
        true ->
            nkserver_ot:tag_error(Id, Error);
        false ->
            ok
    end;

error(_Error, _Span) ->
    continue.


%% @private
do_trace(?LEVEL_EVENT, Type, [], [], Data, Span) when Type==span_started; Type==tags ->
    do_audit(?LEVEL_EVENT, Type, [], [], Data, Span);

do_trace(Level, Type, Txt, Args, Data, #nkserver_span{id=SpanId}=Span) ->
    case Level >= trace_level(Span) of
        true ->
            Data2 = case Type of
                tags -> #{};
                _ -> Data
            end,
            Txt2 = [
                case Level of
                    ?LEVEL_TRACE -> [];
                    ?LEVEL_EVENT -> "EVENT '~s' ";
                    _ -> "[~s] "
                end,
                Txt,
                case map_size(Data2) of
                    0 -> [];
                    _ ->" (~p)"
                end
            ],
            Args2 =
                case Level of
                    ?LEVEL_TRACE -> [];
                    _ -> [Type]
                end ++
                Args ++
                case map_size(Data2) of
                    0 -> [];
                    _ -> [Data]
                end,
            %lager:info("TRACE "++lists:flatten(Txt2), Args2),
            nkserver_ot:log(SpanId, lists:flatten(Txt2), Args2),
            do_audit(Level, Type, Txt, Args, Data, Span);
        false ->
            do_audit(Level, Type, Txt, Args, Data, Span)
    end;

do_trace(Level, Type, Txt, Args, Data, Span) ->
    do_audit(Level, Type, Txt, Args, Data, Span).


%% @private
do_audit(Level, Type, Txt, Args, Data, #nkserver_span{meta=Meta}=Span) ->
    case Level >= audit_level(Span) of
        true ->
            Reason = case Txt of
                undefined ->
                    <<>>;
                _ ->
                    to_bin(io_lib:format(Txt, Args))
            end,
            Core = [app, group, resource, target, namespace],
            BaseMeta = maps:with(Core, Meta),
            ExtraMeta = maps:without(Core, Meta),
            AuditMsg = BaseMeta#{
                level => Level,
                type => Type,
                reason => Reason,
                data => Data,
                metadata => ExtraMeta
            },
            ok = netcomp_rcp_util:send_audit_trace(AuditMsg),
            do_lager(Level, Type, Txt, Args, Data, Span);
        false ->
            do_lager(Level, Type, Txt, Args, Data, Span)
    end;

do_audit(Level, Type, Txt, Args, Data, Span) ->
    do_lager(Level, Type, Txt, Args, Data, Span).


%% @private
do_lager(Level, Type, Txt, Args, Data, #nkserver_span{name=Name, meta=Meta}=Span) ->
    case Level >= log_level(Span) of
        true ->
            Txt2 = [
                "~s ",
                case Level of
                    ?LEVEL_EVENT -> "EVENT '~s' ";
                    _ -> []
                end,
                case Txt of
                    undefined -> [];
                    _ -> Txt
                end,
                case map_size(Data) of
                    0 -> [];
                    _ ->" (~p)"
                end,
                case map_size(Meta) of
                    0 -> [];
                    _ -> " [~p]"
                end
            ],
            Args2 =
                [Name] ++
                case Level of
                    ?LEVEL_EVENT -> [Type];
                    _ -> []
                end ++
                Args ++
                case map_size(Data) of
                    0 -> [];
                    _ -> [Data]
                end ++
                case map_size(Meta) of
                    0 -> [];
                    _ -> [Meta]
                end,
            lager:log(nkserver_trace:level_to_lager(Level), [], lists:flatten(Txt2), Args2);
        false ->
            ok
    end;

do_lager(_Level, _Type, _Txt, _Args, _Data, _Span) ->
    ok.


%% @private
trace_level(#nkserver_span{levels=Levels}) ->
    nklib_util:get_value(trace, Levels, off).


%% @private
log_level(#nkserver_span{levels=Levels}) ->
    nklib_util:get_value(log, Levels, debug).


%% @private
audit_level(#nkserver_span{levels=Levels}) ->
    nklib_util:get_value(trace, Levels, off).


%%%% @private
%%json(Data) ->
%%     case catch nklib_json:encode(Data) of
%%        {'EXIT', _} ->
%%            lager:error("Error encoding JSON: ~p", [Data]),
%%            <<"{}">>;
%%        Json ->
%%            Json
%%    end.


%% @private
to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) -> nklib_util:to_binary(Term).

