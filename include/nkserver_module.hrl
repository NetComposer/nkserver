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

%% On each included file, it adds the following element to the source file,
%% using parse transform in nkserver_dispatcher module:
%%
%% -on_load({nkserver_on_load/0}).
%%
%% nkserver_on_load() -> nkserver_dispatcher:module_loaded(?MODULE).
%%
%% nkserver_dispatcher() -> (module)_dispatcher_module
%%
%% Each time the module is reloaded, it signals nkpacket to see if it is an
%% 'external reload', in that case the reload is aborted and the module is
%% recompiled by nkpacket
%%
%% If we don't include this transform, and the module is hot-reloaded, it will
%% lose all callback functions and package will fail inmeditely


-ifndef(NKSERVER_MODULE_HRL_).
-define(NKSERVER_MODULE_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================

-compile({parse_transform, nkserver_dispatcher}).
-endif.

