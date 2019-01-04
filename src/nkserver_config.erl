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

-module(nkserver_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([config/2, get_plugin_mod/1, get_callback_mod/1]).

-include("nkserver.hrl").

%% ===================================================================
%% Public
%% ===================================================================


%% @doc
config(Spec, OldPackage) ->
    try
        do_config(Spec, OldPackage)
    catch
        throw:Throw ->
            Throw
    end.


%% @private
do_config(#{id:=Id, class:=Class}=Spec, OldPackage) ->
    % Take UUID from Spec, or the old Package if not there, or create it
    UUID = case Spec of
        #{uuid:=SpecUUID} ->
            case OldPackage of
                #{uuid:=ServiceUUID} when ServiceUUID /= SpecUUID ->
                    throw({error, uuid_cannot_be_updated});
                _ ->
                    SpecUUID
            end;
        _ ->
            update_uuid(Id, Spec)
    end,
    case maps:get(id, OldPackage, Id) of
        Id ->
            ok;
        _ ->
            throw({error, id_cannot_be_updated})
    end,
    case maps:get(class, OldPackage, Class) of
        Class ->
            ok;
        _ ->
            throw({error, class_cannot_be_updated})
    end,
    Plugins = maps:get(plugins, Spec, maps:get(plugins, OldPackage, [])),
    Package1 = Spec#{
        uuid => UUID,
        plugins => Plugins,
        timestamp =>  nklib_date:epoch(msecs)
    },
    Package2 = config_plugins(Package1),
    Package3 = config_cache(Package2),
    {ok, Package3}.


%% @private
config_plugins(Package) ->
    #{id:=Id, class:=Class, plugins:=Plugins} = Package,
    PkgMod = case nkserver_util:get_package_class_module(Class) of
        undefined ->
            throw({error, {package_class_invalid, Class}});
        PkgMod0 ->
            PkgMod0
    end,
    % Plugins2 is the expanded list of plugins, first bottom, last top (Id)
    Plugins2 = expand_plugins(Id, [PkgMod|Plugins]),
    ?PKG_LOG(debug, "starting configuration", [], Package),
    % High to low
    Package2 = config_plugins(lists:reverse(Plugins2), Package),
    Hash = erlang:phash2(maps:without([hash, uuid], Package2)),
    Package2#{
        expanded_plugins => Plugins2,
        hash => Hash
    }.


%% @private
config_plugins([], Package) ->
    Package;

config_plugins([Id|Rest], #{id:=Id}=Package) ->
    config_plugins(Rest, Package);

config_plugins([PluginId|Rest], #{class:=Class, id:=Id, config:=Config}=Package) ->
    Mod = get_plugin_mod(PluginId),
    ?PKG_LOG(debug, "calling config for ~s (~s)", [Id, Mod], Package),
    Config2 = case nklib_util:apply(Mod, plugin_config, [Id, Class, Config, Package]) of
        ok ->
            Config;
        not_exported ->
            Config;
        continue ->
            Config;
        {ok, NewConfig} ->
            NewConfig;
        {error, Error} ->
            throw({error, {package_config_error, {Id, Error}}})
    end,
    config_plugins(Rest, Package#{config:=Config2}).


%% @private
config_cache(Package) ->
    #{expanded_plugins:=Plugins} = Package,
    Cache = config_cache(Plugins, Package, #{}),
    Package#{config_cache => Cache}.


%% @private
config_cache([], _Package, Acc) ->
    Acc;

config_cache([Id|Rest], #{id:=Id}=Package, Acc) ->
    config_cache(Rest, Package, Acc);

config_cache([PluginId|Rest], #{class:=Class, id:=Id, config:=Config}=Package, Acc) ->
    Mod = get_plugin_mod(PluginId),
    ?PKG_LOG(debug, "calling config cache for ~s (~s)", [Id, Mod], Package),
    Acc2 = case nklib_util:apply(Mod, plugin_cache, [Id, Class, Config, Package]) of
        ok ->
            Acc;
        {ok, Map} when is_map(Map) ->
            Acc#{PluginId => Map};
        not_exported ->
            Acc;
        continue ->
            Acc
    end,
    config_cache(Rest, Package, Acc2).


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
    Mod = get_plugin_mod(Plugin),
    Group = case nklib_util:apply(Mod, plugin_group, []) of
        not_exported -> undefined;
        continue -> undefined;
        Group0 -> Group0
    end,
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
    LogPath = nkserver_app:get(logPath),
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



