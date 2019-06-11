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

-module(nkserver_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([config/4, get_plugin_mod/1, get_callback_mod/1]).

-include("nkserver.hrl").

%% ===================================================================
%% Public
%% ===================================================================


%% @doc
config(SrvId, PkgClass, Opts, OldService) ->
    try
        case get_spec(SrvId, PkgClass, Opts) of
            {ok, Spec} ->
                do_config(Spec, OldService);
            {error, Error} ->
                {error, Error}
        end
    catch
        throw:Throw ->
            Throw
    end.



-spec get_spec(nkserver:id(), nkserver:class(), nkserver:spec()) ->
    {ok, nkserver:service()} | {error, term()}.

get_spec(SrvId, PkgClass, Opts) ->
    code:ensure_loaded(SrvId),
    Opts2 = case erlang:function_exported(SrvId, config, 1) of
        true ->
            SrvId:config(Opts);
        false ->
            Opts
    end,
    Syntax = #{
        uuid => binary,
        plugins => {list, atom},
        use_module => module,
        use_master => boolean,
        master_min_nodes => {integer, 0, none},
        '__allow_unknown' => true
    },
    case nklib_syntax:parse(Opts2, Syntax) of
        {ok, Opts3, _} ->
            CoreOpts = [
                uuid, plugins, use_module, use_master, master_min_nodes
            ],
            Opts4 = maps:with(CoreOpts, Opts3),
            Config = maps:without(CoreOpts, Opts3),
            Spec = Opts4#{
                id => SrvId,
                class => PkgClass,
                config => Config
            },
            {ok, Spec};
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_config(#{id:=Id, class:=Class}=Spec, OldService) ->
    % Take UUID from Spec, or the old Service if not there, or create it
    UUID = case Spec of
        #{uuid:=SpecUUID} ->
            case OldService of
                #{uuid:=ServiceUUID} when ServiceUUID /= SpecUUID ->
                    throw({error, uuid_cannot_be_updated});
                _ ->
                    SpecUUID
            end;
        _ ->
            update_uuid(Id, Spec)
    end,
    case maps:get(id, OldService, Id) of
        Id ->
            ok;
        _ ->
            throw({error, id_cannot_be_updated})
    end,
    case maps:get(class, OldService, Class) of
        Class ->
            ok;
        _ ->
            throw({error, class_cannot_be_updated})
    end,
    UseMaster = case {Spec, OldService} of
        {#{use_master:=UseMaster0}, #{use_master:=UseMaster0}} ->
            UseMaster0;
        {#{use_master:=_}, #{use_master:=_}} ->
            throw({error, use_master_cannot_be_updated});
        {#{use_master:=UseMaster0}, _} ->
            UseMaster0;
        {_, #{use_master:=UseMaster0}} ->
            UseMaster0;
        {_, _} ->
            false
    end,
    MinNodes = maps:get(master_min_nodes, Spec, maps:get(master_min_nodes, OldService, 0)),
    Plugins = maps:get(plugins, Spec, maps:get(plugins, OldService, [])),
    Service1 = Spec#{
        uuid => UUID,
        plugins => Plugins,
        use_master => UseMaster,
        master_min_nodes => MinNodes,
        timestamp => nklib_date:epoch(msecs)
    },
    Service2 = config_plugins(Service1),
    Service3 = config_cache(Service2),
    {ok, Service3}.


%% @private
config_plugins(Service) ->
    #{id:=Id, class:=Class, plugins:=Plugins} = Service,
    % Plugins2 is the expanded list of plugins, first bottom, last top (Id)
    Plugins2 = expand_plugins(Id, [Class|Plugins]),
    ?SRV_LOG(debug, "starting configuration", [], Service),
    Meta = get_meta(Class),
    Service2 = case Meta of
        #{use_master:=true} ->
            Service#{use_master := true};
        _ ->
            Service
    end,
    % High to low
    Service3 = config_plugins(lists:reverse(Plugins2), Service2),
    Hash = erlang:phash2(maps:without([hash, uuid], Service3)),
    Service3#{
        expanded_plugins => Plugins2,
        hash => Hash
    }.


%% @private
config_plugins([], Service) ->
    Service;

config_plugins([Id|Rest], #{id:=Id}=Service) ->
    config_plugins(Rest, Service);

config_plugins([PluginId|Rest], #{id:=Id, config:=Config}=Service) ->
    Mod = get_plugin_mod(PluginId),
    ?SRV_LOG(debug, "calling config for ~s (~s)", [Id, Mod], Service),
    Config2 = case nklib_util:apply(Mod, plugin_config, [Id, Config, Service]) of
        ok ->
            Config;
        not_exported ->
            Config;
        continue ->
            Config;
        {ok, NewConfig} ->
            NewConfig;
        {error, Error} ->
            throw({error, {service_config_error, {Id, Error}}})
    end,
    config_plugins(Rest, Service#{config:=Config2}).


%% @private
%% Generates:
%%
%% config_cache: map of values that later on will generate the function:
%% 'config_cache(PluginId, Key) -> Value'
%% and can be used as nkserver:get_cached_config(SrvId, PluginId, Key)
%%
%% config_funs: list of entries [{callback_fun_name, Arity, SyntaxTree}]
%% that will be added to the dispatcher module

config_cache(Service) ->
    #{expanded_plugins:=Plugins} = Service,
    {Cache, CBs} = config_cache(Plugins, Service, #{}, []),
    Service#{config_cache => Cache, config_callbacks=>CBs}.


%% @private
config_cache([], _Service, CacheAcc, CBsAcc) ->
    {CacheAcc, CBsAcc};

config_cache([Id|Rest], #{id:=Id}=Service, CacheAcc, CBsAcc) ->
    config_cache(Rest, Service, CacheAcc, CBsAcc);

config_cache([PluginId|Rest], #{id:=Id, config:=Config}=Service, CacheAcc, CBsAcc) ->
    Mod = get_plugin_mod(PluginId),
    ?SRV_LOG(debug, "calling config cache for ~s (~s)", [Id, Mod], Service),
    {CacheAcc2, CBsAcc2} = case nklib_util:apply(Mod, plugin_cache, [Id, Config, Service]) of
        ok ->
            {CacheAcc, CBsAcc};
        {ok, Map} when is_map(Map) ->
            {CacheAcc#{PluginId => Map}, CBsAcc};
        {ok, Map, CBs} when is_map(Map), is_list(CBs) ->
            {CacheAcc#{PluginId => Map}, CBsAcc++CBs};
        not_exported ->
            {CacheAcc, CBsAcc};
        continue ->
            {CacheAcc, CBsAcc}
    end,
    config_cache(Rest, Service, CacheAcc2, CBsAcc2).


%% @private
get_plugin_mod(Plugin) ->
    case get_plugin_mod_check(Plugin) of
        undefined ->
            throw({error, {plugin_unknown, Plugin}});
        Mod ->
            Mod
    end.


%% @private
get_plugin_mod_check(Plugin) ->
    Mod = list_to_atom(atom_to_list(Plugin)++"_plugin"),
    case code:ensure_loaded(Mod) of
        {module, _} ->
            Mod;
        {error, nofile} ->
            case code:ensure_loaded(Plugin) of
                {module, _} ->
                    Plugin;
                {error, nofile} ->
                    undefined
            end
    end.


%% @private
get_callback_mod(Plugin) ->
    Mod = list_to_atom(atom_to_list(Plugin)++"_callbacks"),
    case code:ensure_loaded(Mod) of
        {module, _} ->
            Mod;
        {error, nofile} ->
            case code:ensure_loaded(Plugin) of
                {module, _} ->
                    Plugin;
                {error, nofile} ->
                    undefined
            end
    end.


%% @private
get_meta(Plugin) ->
    case get_plugin_mod_check(Plugin) of
        undefined ->
            #{};
        Module ->
            case erlang:function_exported(Module, plugin_meta, 0) of
                true ->
                    Module:plugin_meta();
                false ->
                    #{}
            end

    end.


%% @private Expands a list of plugins with their dependencies
%% First in the returned list will be the higher-level plugins, last one
%% will be 'nkserver' usually
-spec expand_plugins(none|module(), [atom()]) ->
    [module()].

expand_plugins(Callback, ModuleList) ->
    List1 = add_group_deps([nkserver|ModuleList]),
    List2 = add_all_deps(List1, [], []),
    Mods = [M || {M, _} <-List2],
    % Callback module is made dependant on all other plugins, to be the top
    List3 = [{Callback, Mods}|List2],
    case nklib_sort:top_sort(List3) of
        {ok, Sorted} ->
            % Optional plugins could still appear in dependencies, and show up here
            % Filter plugins not having a module, except for callback
            Sorted2 = [
                Plugin ||
                Plugin <- Sorted,
                Plugin == Callback orelse
                get_plugin_mod_check(Plugin) /= undefined],
            Sorted2;
        {error, Error} ->
            throw({error, Error})
    end.


%% @private
%% All plugins belonging to the same 'group' are added a dependency on the 
%% previous plugin in the same group
add_group_deps(Plugins) ->
    add_group_deps(lists:reverse(Plugins), [], #{}).


%% @private
add_group_deps([], Acc, _Groups) ->
    Acc;

add_group_deps([Plugin|Rest], Acc, Groups) when is_atom(Plugin) ->
    add_group_deps([{Plugin, []}|Rest], Acc, Groups);

add_group_deps([{Plugin, Deps}|Rest], Acc, Groups) ->
    Meta = get_meta(Plugin),
    Group = maps:get(group, Meta, undefined),
    case Group of
        undefined ->
            add_group_deps(Rest, [{Plugin, Deps}|Acc], Groups);
        _ ->
            Groups2 = maps:put(Group, Plugin, Groups),
            case maps:find(Group, Groups) of
                error ->
                    add_group_deps(Rest, [{Plugin, Deps}|Acc], Groups2);
                {ok, Last} ->
                    add_group_deps(Rest, [{Plugin, [Last|Deps]}|Acc], Groups2)
            end
    end.


%% @private
add_all_deps([], _Optional, Acc) ->
    Acc;

add_all_deps([Plugin|Rest], Optional, Acc) when is_atom(Plugin) ->
    add_all_deps([{Plugin, []}|Rest], Optional, Acc);

add_all_deps([{Plugin, List}|Rest], Optional, Acc) when is_atom(Plugin) ->
    case lists:keyfind(Plugin, 1, Acc) of
        {Plugin, OldList} ->
            List2 = lists:usort(OldList++List),
            Acc2 = lists:keystore(Plugin, 1, Acc, {Plugin, List2}),
            add_all_deps(Rest, Optional, Acc2);
        false ->
            case get_plugin_deps(Plugin, List, Optional) of
                undefined ->
                    add_all_deps(Rest, Optional, Acc);
                {Deps, Optional2} ->
                    add_all_deps(Deps++Rest, Optional2, [{Plugin, Deps}|Acc])
            end
    end;

add_all_deps([Other|_], _Optional, _Acc) ->
    throw({error, {invalid_plugin_name, Other}}).


%% @private
get_plugin_deps(Plugin, BaseDeps, Optional) ->
    case get_plugin_mod_check(Plugin) of
        undefined ->
            case lists:member(Plugin, Optional) of
                true ->
                    undefined;
                false ->
                    throw({error, {plugin_unknown, Plugin}})
            end;
        Mod ->
            {Deps1, Optional2} = case nklib_util:apply(Mod, plugin_deps, []) of
                List when is_list(List) ->
                    get_plugin_deps_list(List, [], Optional);
                not_exported ->
                    {[], Optional};
                continue ->
                    {[], Optional}
            end,
            Deps2 = lists:usort(BaseDeps ++ [nkserver|Deps1]) -- [Plugin],
            {Deps2, Optional2}
    end.


%% @private
get_plugin_deps_list([], Deps, Optional) ->
    {Deps, Optional};

get_plugin_deps_list([{Plugin, optional}|Rest], Deps, Optional) when is_atom(Plugin) ->
    get_plugin_deps_list(Rest, [Plugin|Deps], [Plugin|Optional]);

get_plugin_deps_list([Plugin|Rest], Deps, Optional) when is_atom(Plugin) ->
    get_plugin_deps_list(Rest, [Plugin|Deps], Optional).


%% @private
update_uuid(Id, Spec) ->
    LogPath = nkserver_app:get(log_path),
    Path = filename:join(LogPath, atom_to_list(Id)++".uuid"),
    case read_uuid(Path) of
        {ok, UUID} ->
            UUID;
        {error, Path} ->
            save_uuid(Path, nklib_util:uuid_4122(), Spec)
    end.


%% @private
read_uuid(Path) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            case binary:split(Binary, <<$,>>) of
                [UUID|_] when byte_size(UUID)==36 -> {ok, UUID};
                _ -> {error, Path}
            end;
        _ ->
            {error, Path}
    end.


%% @private
save_uuid(Path, UUID, Spec) ->
    Content = io_lib:format("~p", [Spec]),
    case file:write_file(Path, Content) of
        ok ->
            UUID;
        Error ->
            lager:warning("NkSERVER: Could not write file ~s: ~p", [Path, Error]),
            UUID
    end.








%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).



