%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(nkserver_dispatcher).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([parse_transform/2,  compile/1, module_loaded/1]).

-include("nkserver.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Parse transform for nkserver main callback modules
%% - adds '-on_load({nkserver_on_load/0}).'
%% - adds 'nkserver_on_load() -> nkserver_dispatcher:module_loaded(?MODULE).'
%% - adds 'nkserver_dispatcher() -> (module)_nkserver_dispatcher.'
parse_transform(Forms, _Opts) ->
    % io:format("OPTS2: ~p\n", [_Opts]),
    Mod = nklib_code:forms_find_attribute(module, Forms),
    Dispatcher = gen_dispatcher_mod(Mod),
    Attrs = [
        erl_syntax:attribute(
            erl_syntax:atom(on_load),
            [erl_syntax:abstract({nkserver_on_load, 0})]
        ),
        nklib_code:export_attr([{nkserver_dispatcher, 0}])
    ],
    Forms2 = nklib_code:forms_add_attributes(Attrs, Forms),
    Funs = [
        erl_syntax:function(
            erl_syntax:atom(nkserver_on_load), [
                erl_syntax:clause(none, [
                    erl_syntax:application(
                        erl_syntax:atom(nkserver_dispatcher),
                        erl_syntax:atom(module_loaded),
                        [erl_syntax:abstract(Mod)])
                    ])
            ]
        ),
        erl_syntax:function(
            erl_syntax:atom(nkserver_dispatcher), [
                erl_syntax:clause(none, [
                    erl_syntax:abstract(Dispatcher)
                ])
            ]
        )
    ],
    Forms3 = nklib_code:forms_add_funs(Funs, Forms2),
    Forms4 = erl_syntax:revert_forms(Forms3),
    % nklib_code:forms_print(Forms4),
    Forms4.


%% @doc Called to generate the dispatcher module
compile(#{id:=Id}=Service) ->
    maybe_generate_mod(Id),
    {DispatcherMod, ModForms} = make_module(Service),
    Opts = [report_errors, report_warnings],
    {ok, _Tree} = nklib_code:do_compile(DispatcherMod, ModForms, Opts),
    ok.


%% @doc Called from function nkserver_on_load/0 in callback module
%% - if no service is running, ignore and load the module
%% - if it is running, and the reload is not because of our recompilation
%%   we abort the loading and recompile ourselves
%% - if it is running, but the reload is from our our recompilation
%%   (we took all attributes from original module, including on_load)
module_loaded(Id) ->
    case whereis(Id) of
        Pid when is_pid(Pid) ->
            lager:notice("NkSERVER: Module ~s reloaded, recompiling dispatcher", [Id]),
            nkserver_srv:recompile(Pid),
            ok;
        undefined ->
            ok
    end.



%% @doc Generates a barebones callback module if it is doesn't exist
maybe_generate_mod(Id) ->
    code:ensure_loaded(Id),
    case erlang:function_exported(Id, nkserver_dispatcher, 0) of
        true ->
            ok;
        false ->
            Forms = [
                erl_syntax:attribute(erl_syntax:atom(module), [erl_syntax:atom(Id)]),
                nklib_code:export_attr([{nkserver_dispatcher, 0}]),
                erl_syntax:function(
                    erl_syntax:atom(nkserver_dispatcher), [
                        erl_syntax:clause(none, [
                            erl_syntax:abstract(gen_dispatcher_mod(Id))
                        ])
                    ]
                ),
                erl_syntax:eof_marker()
            ],
            Opts = [report_errors, report_warnings],
            {ok, _} = nklib_code:do_compile(Id, Forms, Opts)
    end.



%% @private
make_module(#{id:=Id}=Service) ->
    ?SRV_LOG(debug, "starting dispatcher recompilation...", [], Service),
    ServiceKeys = [
        id, class, uuid, hash, timestamp, plugins, expanded_plugins,
        config, config_cache
    ],
    {ServiceExported, ServiceFuns} = make_service_funs(ServiceKeys, Service),
    PluginList = maps:get(expanded_plugins, Service),
    {PluginExported, PluginFuns} = make_plugin_funs(PluginList, Id),
    {CacheExported, CacheFuns} = make_cache_funs(Service),
    AllFuns = ServiceFuns ++ PluginFuns ++ CacheFuns,
    AllExported = ServiceExported ++ PluginExported ++ CacheExported,
    ModForms = make_module(Id, AllExported, AllFuns),
    DispatcherMod = gen_dispatcher_mod(Id),
    case nkserver_app:get(saveDispatcherSource) of
        true ->
            Path = nkserver_app:get(logPath),
            ?SRV_LOG(debug, "saving to disk...", [], Service),
            ok = nklib_code:write(DispatcherMod, ModForms, Path);
        false ->
            ok
    end,
    ?SRV_LOG(info, "dispatcher compilation completed", [], Service),
    {DispatcherMod, ModForms}.


%% @private
make_service_funs(FunIds, Service) ->
    Export = [{Id, 0} || Id <- FunIds],
    Funs = lists:foldl(
        fun(K, Acc) -> [nklib_code:getter(K, maps:get(K, Service))|Acc] end,
        [],
        FunIds),
    {Export, Funs}.


%% @private Extracts all callbacks from all plugins (included main module)
make_plugin_funs(Plugins, Id) ->
    make_plugin_funs(Plugins, Id, #{}).


%% @private
make_plugin_funs([Plugin|Rest], Id, Map) ->
    case nkserver_config:get_callback_mod(Plugin) of
        undefined ->
            make_plugin_funs(Rest, Id, Map);
        Mod ->
            case nklib_code:get_funs(Mod) of
                error ->
                    make_plugin_funs(Rest, Id, Map);
                List ->
                    % List of {Name, Arity} defined for this module
                    Map2 = make_plugin_funs_deep(List, Mod, Map),
                    make_plugin_funs(Rest, Id, Map2)
            end
    end;

make_plugin_funs([], _Id, Map) ->
    Funs = maps:fold(
        fun({Fun, Arity}, {Value, Pos}, Acc) ->
            [nklib_code:fun_expr(Fun, Arity, Pos, [Value])|Acc]
        end,
        [],
        Map),
    {maps:keys(Map), Funs}.


%% @private
make_plugin_funs_deep([], _Mod, Map) ->
    Map;

make_plugin_funs_deep([{Fun, Arity}|Rest], Mod, Map) ->
    % If it is the main module, we call to ourselves, to the renamed version
    {Pos, Value} = case maps:find({Fun, Arity}, Map) of
        error ->
            % If {Fun, Arity} is not yet in the map, set the base (direct call) syntax
            {1, nklib_code:call_expr(Mod, Fun, Arity, 1)};
        {ok, {Syntax, Pos0}} ->
            % If {Fun, Arity} is in the map, it already has a syntax on it,
            % add a new case expression around it
            {Pos0+1, nklib_code:case_expr(Mod, Fun, Arity, Pos0+1, [Syntax])}
    end,
    Map2 = maps:put({Fun, Arity}, {Value, Pos}, Map),
    make_plugin_funs_deep(Rest, Mod, Map2).


%% @private
make_cache_funs(#{config_cache:=Cache}) ->
    Values = maps:fold(
        fun(PluginId, Map, Acc) ->
            maps:fold(
                fun(Key, Val, Acc2) ->
                    [{[PluginId, Key], Val}|Acc2]
                end,
                Acc,
                Map)
        end,
        [],
        Cache),
    Funs = [nklib_code:getter_args(config_cache, 2, Values, undefined)],
    {[{config_cache, 2}], Funs}.


%% @private Generates the full module
make_module(Id, Exported, Funs) ->
    Mod = gen_dispatcher_mod(Id),
    Attrs = [
        erl_syntax:attribute(erl_syntax:atom(module), [erl_syntax:atom(Mod)]),
        nklib_code:export_attr(Exported)
    ],
    DispatcherForms = Attrs ++ Funs ++ [erl_syntax:eof_marker()],
    % Remove the "tree" version than erl_syntax utilities generate
    erl_syntax:revert_forms(DispatcherForms).



%% @private
gen_dispatcher_mod(Id) -> list_to_atom(atom_to_list(Id)++"_nkserver_dispatcher").


%%%% @doc Called to generate the dispatcher module
%%compile(#{id:=Id}=Service) ->
%%    ModForms1 = get_ebin_forms(Id),
%%    ModForms2 = make_module(Service, ModForms1),
%%    ok = nklib_store:put({nkserver_in_compile, Id}, true, [{ttl, 5}]),
%%    % We include debug_info here because it seems c() in the sell will somehow
%%    % take these settings. If not, c() will remove the debug_info from beam
%%    {ok, _Tree} = nklib_code:do_compile(Id, ModForms2,
%%        [report_errors, report_warnings, debug_info]),
%%    nklib_store:del({nkserver_in_compile, Id}),
%%    ok.
%%
%%
%%
%%%%%% @doc Called from function nkserver_on_load/0 in callback module
%%%%%% - if no package is running, ignore and load the module
%%%%%% - if it is running, and the reload is not because of our recompilation
%%%%%%   we abort the loading and recompile ourselves
%%%%%% - if it is running, but the reload is from our our recompilation
%%%%%%   (we took all attributes from original module, including on_load)
%%module_loaded(Id) ->
%%    lager:error("NKLOG MODULE LOADED ~p", [Id]),
%%    case whereis(Id) of
%%        Pid when is_pid(Pid) ->
%%            % The package is active
%%            case nklib_store:get({nkserver_in_compile, Id}) of
%%                true ->
%%                    % The load event is because of our compilation, so proceed
%%                    lager:info("NkSERVER: completing reloading of ~s", [Id]),
%%                    nklib_store:del({nkserver_in_compile, Id}),
%%                    ok;
%%                _ ->
%%                    % It is an external reloading
%%                    % Abort it and perform a code compilation
%%                    lager:notice("NkSERVER: Module ~s has been reloaded, recompiling", [Id]),
%%                    nkserver_srv:recompile(Pid),
%%                    error
%%            end;
%%        undefined ->
%%            io:format("\n\n\nNkSERVER: Ignoring reloading of inactive ~s\n\n\n", [Id]),
%%            ok
%%    end.
%%
%%
%%%% @private
%%make_module(#{id:=Id}=Service, ModForms) ->
%%    ?SRV_LOG(debug, "starting dispatcher recompilation...", [], Service),
%%    {ExternalFuns, InternalFuns} = find_module_funs(ModForms),
%%    ExternalFuns2 = rename_external_funs(ExternalFuns),
%%    ServiceKeys = [id, class, uuid, hash, timestamp, plugins, expanded_plugins, config_cache],
%%    {ServiceExported, ServiceFuns} = make_package_funs(ServiceKeys, Service),
%%    PluginList = maps:get(expanded_plugins, Service),
%%    ExternalExported = [{Name, Arity} || {function, _, Name, Arity, _} <- ExternalFuns],
%%    {PluginExported, PluginFuns} = make_plugin_funs(PluginList, Id, ExternalExported),
%%    {CacheExported, CacheFuns} = make_cache_funs(Service),
%%    AllFuns = InternalFuns ++ ExternalFuns2 ++ ServiceFuns ++ PluginFuns ++ CacheFuns,
%%    AllExported = ServiceExported ++ PluginExported ++ CacheExported,
%%    ModForms2 = make_module(Id, AllExported, AllFuns, ModForms),
%%    case nkserver_app:get(saveDispatcherSource) of
%%        true ->
%%            LogPath = nkserver_app:get(logPath),
%%            ?SRV_LOG(debug, "saving to disk...", [], Service),
%%            ok = nklib_code:write(nklib_util:to_list(Id) ++ "_compiled", ModForms2, LogPath);
%%        false ->
%%            ok
%%    end,
%%    ?SRV_LOG(info, "dispatcher compilation completed", [], Service),
%%    ModForms2.



%%%% @doc Finds external and local functions in module
%%get_ebin_forms(Id) ->
%%    code:ensure_loaded(Id),
%%    case code:get_object_code(Id) of
%%        {Id, Bin, _File} ->
%%            {ok,{_,[{abstract_code,{_, Forms}}]}} = beam_lib:chunks(Bin, [abstract_code]),
%%            Forms;
%%        error ->
%%            []
%%    end.
%%
%%
%%%% @doc Finds external and local functions in module
%%find_module_funs(Forms) ->
%%    Exported = nklib_code:forms_find_exported(Forms),
%%    find_used(Forms, Exported, [], []).
%%
%%
%%%% @private
%%find_used([], _Exported, ExtAcc, IntAcc) ->
%%    {ExtAcc, IntAcc};
%%
%%find_used([{function, _Line, Name, Arity, _Spec}=Fun|Rest], Exported, ExtAcc, IntAcc) ->
%%    case lists:member({Name, Arity}, Exported) of
%%        true ->
%%            find_used(Rest, Exported, [Fun|ExtAcc], IntAcc);
%%        false ->
%%            find_used(Rest, Exported, ExtAcc, [Fun|IntAcc])
%%    end;
%%
%%find_used([_|Rest], Exported, ExtAcc, IntAcc) ->
%%    find_used(Rest, Exported, ExtAcc, IntAcc).
%% @private Rename all external functions in module as "fun_"
%% The plugin mechanism will generate new external functions with the same name,
%% calling to this internal ones.


%%rename_external_funs(ExternalFuns) ->
%%    [
%%        {function, Line, gen_local_name(Name), Arity, Spec}
%%        || {function, Line, Name, Arity, Spec} <- ExternalFuns
%%    ].


%%%% @private
%%gen_local_name(Fun) -> list_to_atom(atom_to_list(Fun)++"_").


