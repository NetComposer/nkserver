-ifndef(NKSERVER_HRL_).
-define(NKSERVER_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================


%% ===================================================================
%% Records
%% ===================================================================


-define(SRV_LOG(Type, Txt, Args, Service),
    lager:Type("NkSERVER srv '~s' (~s) "++Txt, [maps:get(id, Service), maps:get(class, Service) | Args])).


%% The callback module should have generated this function after parse transform
-define(CALL_SRV(Id, Fun, Args), apply(Id, nkserver_callback, [Fun, Args])).


-endif.

