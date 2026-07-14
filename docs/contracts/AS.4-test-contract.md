# AS.4 Test Contract — local explore config and CLI exposure

This document maps every acceptance criterion of the AS.4 local explore-mode
slice (issue #232) to the single test case that proves it. The local config and
CLI expose the bounded exploration behavior already owned by `soma_actor`;
they do not add another exploration loop.

## Criterion 1 — explore mode reaches the daemon model config

| Guarantee | Proof |
| --- | --- |
| A valid `[llm]` setting of `explore = true` is carried into the loaded model config. | `soma_config_tests:test_load_carries_explore_true` |

## Criterion 2 — socket asks use both configured explore budgets

| Guarantee | Proof |
| --- | --- |
| A socket ask enforces the configured round limit and observation byte limit. | `soma_cli_server_SUITE:test_explore_ask_uses_configured_round_and_observation_budgets` |

## Criterion 3 — invalid settings emit keyed diagnostics

| Guarantee | Proof |
| --- | --- |
| Invalid explore settings emit bounded diagnostics that identify each rejected key. | `soma_config_tests:test_invalid_explore_settings_emit_keyed_diagnostics` |

## Criterion 4 — an unparseable setting keeps the daemon reachable and off

| Guarantee | Proof |
| --- | --- |
| An unparseable optional explore setting is nonfatal, leaves exploration disabled, and permits daemon ping. | `soma_cli_server_SUITE:test_unparseable_explore_setting_keeps_daemon_reachable_and_off` |

## Criterion 5 — a reader round feeds a terminal socket result

| Guarantee | Proof |
| --- | --- |
| Config-loaded explore mode runs one reader round, carries its bounded observation, and returns the terminal result over the socket. | `soma_cli_server_SUITE:test_config_loaded_explore_ask_returns_terminal_result_with_bounded_observation` |

## Criterion 6 — trace shows exploration rounds in event order

| Guarantee | Proof |
| --- | --- |
| The thin CLI trace path renders the completed exploration rounds in stored event order. | `soma_cli_server_SUITE:test_trace_after_explore_ask_returns_rounds_in_event_order` |

## Criterion 7 — closing the ask socket cancels exploration

| Guarantee | Proof |
| --- | --- |
| Closing a synchronous ask socket during a reader run cancels the actor task and its active run. | `soma_cli_server_SUITE:test_explore_ask_client_disconnect_cancels_actor_task` |

## Criterion 8 — all docmod examples normalize with honest metadata

| Guarantee | Proof |
| --- | --- |
| The help, read, and edit example manifests load through the production config boundary with their declared effects, idempotence, and argv. | `soma_tool_config_SUITE:test_docmod_example_manifests_normalize_with_expected_metadata` |

## Criterion 9 — docmod help preserves argv order

| Guarantee | Proof |
| --- | --- |
| The help example invokes the executable with `help` followed by the substituted topic and no compatibility argument. | `soma_tool_config_SUITE:test_docmod_help_stub_receives_help_then_substituted_topic` |

## Criterion 10 — usage covers explore config and docmod registration

| Guarantee | Proof |
| --- | --- |
| The usage guide documents the explore settings, fail-closed behavior, example manifests, path replacement, and registration commands. | `soma_as4_contract_doc_tests:test_usage_documents_explore_settings_and_docmod_registration` |

## Criterion 11 — this contract maps every criterion

| Guarantee | Proof |
| --- | --- |
| This document names exactly one proving module and case for each acceptance criterion of issue #232. | `soma_as4_contract_doc_tests:test_as4_contract_maps_every_criterion_to_proving_case` |
