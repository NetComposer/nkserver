-ifndef(NKSERVER_HRL_).
-define(NKSERVER_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================

-define(SRV_DELAYED_DESTROY, 3000).

-define(PKG_HTTPPOOL, <<"HttpPool">>).
-define(PKG_REST, <<"RestServer">>).
-define(PKG_WEBSERVER, <<"WebServer">>).
-define(PKG_JOSE, <<"JOSE">>).
-define(PKG_PGSQL, <<"PgSQL">>).


%% ===================================================================
%% Records
%% ===================================================================


-define(SRV_LOG(Type, Txt, Args, Package),
    lager:Type("NkSERVER srv '~s' (~s) "++Txt, [maps:get(id, Package), maps:get(class, Package) | Args])).


%% The callback module should have generated this function after parse transform
-define(CALL_SRV(Id, Fun, Args), apply(Id:nkserver_dispatcher(), Fun, Args)).


-endif.

