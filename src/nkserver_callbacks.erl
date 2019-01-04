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

%% @doc Default plugin callbacks
-module(nkserver_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([msg/1, msg/2, i18n/3]).
-export([package_srv_init/2, package_srv_handle_call/4, package_srv_handle_cast/3,
         package_srv_handle_info/3, package_srv_code_change/4, package_srv_terminate/3,
         package_srv_timed_check/2]).

-export_type([continue/0]).

-include("nkserver.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type continue() :: continue | {continue, list()}.
%-type req() :: #nkreq{}.
-type user_state() :: map().
-type package() :: nkserver:package().



%% ===================================================================
%% Errors Callbacks
%% ===================================================================


%% @doc
-spec msg(nkserver:lang(), nkserver:msg()) ->
    atom() |
    tuple() |
    list() |
    {atom(), string()} |
    {Fmt::string(), Vals::string()} |
    {atom(), Fmt::string(), Vals::string()}.

msg(SrvId, Msg) ->
    ?CALL_SRV(SrvId, msg, [Msg]).


%% @doc
-spec msg(nkserver:msg()) ->
    atom() |
    tuple() |
    list() |
    {atom(), string()} |
    {Fmt::string(), Vals::string()} |
    {atom(), Fmt::string(), Vals::string()}.

msg({field_missing, Txt})	        -> {"Missing field: '~s'", [Txt]};
msg({field_invalid, Txt})	        -> {"Field '~s' is invalid", [Txt]};
msg({field_unknown, Txt})	        -> {"Unknown field: '~s'", [Txt]};
msg(file_read_error)   		        -> "File read error";
msg(internal_error)			        -> "Internal error";
msg({internal_error, Ref})	        -> {"Internal error: ~s", [Ref]};
msg(invalid_parameters) 		    -> "Invalid parameters";
msg(leader_is_down)                 -> "Package leader is down";
msg(normal_termination) 		    -> "Normal termination";
msg(not_found) 				        -> "Not found";
msg(not_implemented) 		        -> "Not implemented";
msg(ok)                             -> "OK";
msg(process_down)  			        -> "Process failed";
msg(process_not_found) 		        -> "Process not found";
msg(package_not_found) 		        -> "Package not found";
msg({syntax_error, Txt})		    -> {"Syntax error: '~s'", [Txt]};
msg({tls_alert, Txt}) 			    -> {"Error TTL: ~s", [Txt]};
msg(timeout) 				        -> "Timeout";
msg(unauthorized) 			        -> "Unauthorized";
msg(_)   		                    -> continue.


%% ===================================================================
%% i18n
%% ===================================================================


%% @doc
-spec i18n(nkserver:id(), nklib_i18n:key(), nklib_i18n:lang()) ->
    <<>> | binary().

i18n(SrvId, Key, Lang) ->
    nklib_i18n:get(SrvId, Key, Lang).



%% ===================================================================
%% Package Server Callbacks
%% ===================================================================

%% @doc Called when a new service starts, first for the top-level plugin
-spec package_srv_init(package(), user_state()) ->
	{ok, user_state()} | {stop, term()}.

package_srv_init(_Package, UserState) ->
	{ok, UserState}.


%% @doc Called when the service process receives a handle_call/3.
-spec package_srv_handle_call(term(), {pid(), reference()}, package(), user_state()) ->
	{reply, term(), user_state()} | {noreply, user_state()} | continue().

package_srv_handle_call(_Msg, _From, _Package, _State) ->
    continue.


%% @doc Called when the NkApp process receives a handle_cast/3.
-spec package_srv_handle_cast(term(), package(), user_state()) ->
	{noreply, user_state()} | continue().

package_srv_handle_cast(_Msg, _Package, _State) ->
    continue.


%% @doc Called when the NkApp process receives a handle_info/3.
-spec package_srv_handle_info(term(), package(), user_state()) ->
	{noreply, user_state()} | continue().

package_srv_handle_info({'EXIT', _, normal}, _Package, State) ->
	{noreply, State};

package_srv_handle_info(_Msg, _Package, _State) ->
    continue.


-spec package_srv_code_change(term()|{down, term()}, package(), user_state(), term()) ->
    ok | {ok, package()} | {error, term()} | continue().

package_srv_code_change(OldVsn, _Package, State, Extra) ->
	{continue, [OldVsn, State, Extra]}.


%% @doc Called when a service is stopped
-spec package_srv_terminate(term(), package(), package()) ->
	{ok, package()}.

package_srv_terminate(_Reason, _Package, State) ->
	{ok, State}.


%% @doc Called periodically
-spec package_srv_timed_check(package(), user_state()) ->
    {ok, user_state()}.

package_srv_timed_check(_Package, State) ->
    {ok, State}.




%%%% ===================================================================
%%%% Package Master Callbacks
%%%% These callbacks are called by the service master process running
%%%% at each node. One of the will be elected master
%%%% ===================================================================
%%
%%
%%%% @doc
%%-spec service_master_init(nkserver:id(), user_state()) ->
%%    {ok, user_state()} | {stop, term()}.
%%
%%service_master_init(_SrvId, UserState) ->
%%    {ok, UserState}.
%%
%%
%%%% @doc
%%-spec service_master_leader(nkserver:id(), boolean(), pid()|undefined, user_state()) ->
%%    {ok, user_state()}.
%%
%%service_master_leader(_SrvId, _IsLeader, _Pid, UserState) ->
%%    {ok, UserState}.
%%
%%
%%%% @doc Find an UUID in global database
%%-spec service_master_find_uid(UID::binary(), user_state()) ->
%%    {reply, #actor_id{}, user_state()} |
%%    {stop, actor_not_found|term(), user_state()} |
%%    continue().
%%
%%service_master_find_uid(_UID, UserState) ->
%%    {stop, actor_not_found, UserState}.
%%
%%
%%%% @doc Called when the service master process receives a handle_call/3.
%%-spec service_master_handle_call(term(), {pid(), reference()}, user_state()) ->
%%    {reply, term(), user_state()} | {noreply, user_state()} | continue().
%%
%%service_master_handle_call(Msg, _From, State) ->
%%    lager:error("Module nkserver_master received unexpected call ~p", [Msg]),
%%    {noreply, State}.
%%
%%
%%%% @doc Called when the service master process receives a handle_cast/3.
%%-spec service_master_handle_cast(term(), user_state()) ->
%%    {noreply, user_state()} | continue().
%%
%%service_master_handle_cast(Msg, State) ->
%%    lager:error("Module nkserver_master received unexpected cast ~p", [Msg]),
%%    {noreply, State}.
%%
%%
%%%% @doc Called when the service master process receives a handle_info/3.
%%-spec service_master_handle_info(term(), user_state()) ->
%%    {noreply, user_state()} | continue().
%%
%%service_master_handle_info({'EXIT', _, normal}, State) ->
%%    {noreply, State};
%%
%%service_master_handle_info(Msg, State) ->
%%    lager:notice("Module nkserver_master received unexpected info ~p", [Msg]),
%%    {noreply, State}.
%%
%%
%%-spec service_leader_code_change(term()|{down, term()}, user_state(), term()) ->
%%    {ok, user_state()} | {error, term()} | continue().
%%
%%service_leader_code_change(_OldVsn, State, _Extra) ->
%%    {ok, State}.
%%
%%
%%%% @doc Called when a service is stopped
%%-spec service_master_terminate(term(), user_state()) ->
%%    ok.
%%
%%service_master_terminate(_Reason, _State) ->
%%    ok.

