#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa ../ -pa .

% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

% Test that we can load each module.

main(_) ->
    test_util:init_code_path(),
    Modules = [
        couch_compress,
        couch_config,
        couch_config_writer,
        couch_db,
        couch_db_update_notifier,
        couch_db_update_notifier_sup,
        couch_db_updater,
        couch_doc,
        % Fails unless couch_config gen_server is started.
        % couch_ejson_compare,
        couch_event_sup,
        couch_external_manager,
        couch_external_server,
        couch_file,
        couch_key_tree,
        couch_os_process,
        couch_query_servers,
        couch_server,
        couch_server_sup,
        couch_stream,
        couch_task_status,
        couch_util,
        couch_work_queue,
        json_stream_parse
    ],

    etap:plan(length(Modules)),
    lists:foreach(
        fun(Module) ->
            etap:loaded_ok(
                Module,
                lists:concat(["Loaded: ", Module])
            )
        end, Modules),
    etap:end_tests().
