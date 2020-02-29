%% -------------------------------------------------------------------
%%
%% Copyright (c) 2020 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(nkserver_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([name/1, parse_config/2]).
-export([get_net_ticktime/0, set_net_ticktime/2]).

-include("nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================




%% ===================================================================
%% Public
%% ===================================================================


%% @private
name(Name) ->
    nklib_parse:normalize(Name, #{space=>$_, allowed=>[$+, $-, $., $_]}).


%% @doc
parse_config(Config, Syntax) ->
    nklib_syntax:parse_all(Config, Syntax).


%% @private
get_net_ticktime() ->
    rpc:multicall(net_kernel, get_net_ticktime, []).


%% @private
set_net_ticktime(Time, Period) ->
    rpc:multicall(net_kernel, set_net_ticktime, [Time, Period]).


