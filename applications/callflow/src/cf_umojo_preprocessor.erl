-module(cf_umojo_preprocessor).

-export([handle_req/2]).

-include("callflow.hrl").

-define(PRESENCE_URL, "http://ivr.umojo.com:21091/RingGroupAvailability/").

-spec handle_req(wh_json:object(), wh_proplist()) -> 'ok'.
handle_req(_Data, Call) ->
    Flow = whapps_call:kvs_fetch('cf_flow', Call),
    DB = wh_util:format_account_id(whapps_call:account_id(Call), 'encoded'),
    ModifiedFlow = wh_json:set_value(
                 <<"flow">>, 
                 recursive_overwrite_ring_groups(
               wh_json:get_value(<<"flow">>, Flow),
               DB
             ),
             Flow),
    cf_exe:branch(ModifiedFlow, Call).

recursive_overwrite_ring_groups_next_child(FP, DB) ->
    OldChild = wh_json:get_value(<<"children">>, FP),
    case wh_json:get_value(<<"_">>, OldChild) of
        undefined ->
        %% There's no more children. Pack it up. You're done
            FP;
        SomeChild ->
            %% recursive overwrite any ring groups in the children
            wh_json:set_value(
                <<"children">>,
                wh_json:set_value(
                    <<"_">>,
            recursive_overwrite_ring_groups(SomeChild, DB),
                    OldChild),
                FP)
    end.          

recursive_overwrite_ring_groups(FlowPart, DB) ->
    case wh_json:get_value(<<"module">>, FlowPart) of
        <<"ring_group">> ->
        F1 = wh_json:set_value(
          <<"data">>,
          construct_pivot(FlowPart, DB),
          FlowPart),
    
        recursive_overwrite_ring_groups_next_child(F1, DB);
    _ ->
       %% Not a ring group, but the rabbit hole continues
       recursive_overwrite_ring_groups_next_child(FlowPart, DB)
    end.

construct_pivot(FP, DB) ->
    DP = wh_json:get_value(<<"data">>, FP),
    DP2 = wh_json:set_value(<<"endpoints">>,
                    wh_json:map(fun(EndPointObj) ->
                        ID = wh_json:get_value(<<"id">>, EndPointObj),
                  Args = [{'key', ID}],
                  {'ok', [Jobj|_]} = couch_mgr:get_results(DB, 
                                                             <<"users">>, 
                                                             Args),
                      UserPlist = wh_json:recursive_to_proplist(Jobj),
                     Email = proplists:get_value(<<"email">>, UserPlist),
                              wh_json:set_value(<<"email">>,
                                    Email,
                        EndPointObj)
                end,
                wh_json:get_value(<<"endpoints">>, DP)),
                  DP),
    FlowPart2 = wh_json:set_value(<<"data">>, 
                    wh_json:set_value(<<"voice_url">>,
                                      ?PRESENCE_URL ++ 
                      "?data=" ++ 
                      edoc_lib:escape_uri(DP2),
                wh_json:set_value(<<"req_format">>,
                              <<"kazoo">>,
                wh_json:set_value(<<"method">>,
                          <<"post">>,
                          wh_json:new()))),
            FP),
    wh_json:set_value(<<"module">>, <<"pivot">>, FlowPart2).
