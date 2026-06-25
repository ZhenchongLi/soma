# [cc] Bundle soma_actor in the relx release + boot smoke test

## Current state

The relx release in `rebar.config` names four apps: `soma_event_store`,
`soma_tools`, `soma_runtime`, `sasl`. That is the execution core. The v0.4
`soma_actor` app is built and tested but left out of the packaged release on
purpose, a decision #73 made and recorded.

`docs/release.md` matches that. Its "Bundled apps" list has four bullets and no
`soma_actor` bullet. A prose paragraph says the actor "is deliberately **not yet
bundled**" and calls bundling-it-with-a-smoke-test a follow-up.

`apps/soma_tools/test/soma_release_app_list_tests.erl` pins the two together. It
reads the release app list out of `rebar.config`, reads the backtick-bulleted app
names out of `docs/release.md`, and asserts the two sets are equal. A second test
asserts the doc contains both "soma_actor" and "not yet bundled". So the doc and
the config can't drift apart without the EUnit gate going red.

This is insufficient because the follow-up #73 promised never happened. An
unpacked release can boot the runtime core but cannot start an actor — the actor
app is not in the tarball. There is also no documented way to boot a packaged
release and run an actor task end to end, the way the session smoke test already
documents for `soma_agent_session`.

## Approach

Add `soma_actor` to the four places that have to agree, and add the actor smoke
test to the doc. No runtime code changes — `soma_actor`, `soma_actor_sup`, and
the runtime stay exactly as they are.

Four edits:

1. `rebar.config`: add `soma_actor` to the `{release, {soma, "0.1.0"}, [...]}`
   app list. The actor app already declares `soma_runtime` in its
   `applications`, so the runtime is pulled in regardless. But relx only packages
   and boots the apps the release list names by hand, so the actor has to be
   named there to ship. Put it after `soma_runtime` and before `sasl` so the
   list reads bottom-up (the layer on top of the runtime, then the OTP infra
   app), and so the order still matches the doc bullet order.

2. `docs/release.md`: add a `` - `soma_actor` `` bullet to the "Bundled apps"
   list, in the same position relative to the others as in `rebar.config`.

3. `docs/release.md`: remove the "not yet bundled" prose. The paragraph that
   says the actor is excluded is now false, so it goes. Replace it with one line
   that says the actor layer is bundled and the embedding application starts
   actors on top of the runtime. The phrase "not yet bundled" must not appear
   anywhere in the file — criterion 3 checks the whole file, not one line.

4. `docs/release.md`: add an actor boot smoke test section, modeled on the
   existing session smoke test. It uses `soma_actor_sup:start_actor/1` to start
   an actor against the booted runtime's event store, sends a one-step `echo`
   steps envelope, polls `soma_actor:get_task_status/2` until the task reads
   `completed`, and confirms the actor process is still alive. This is a manual
   `bin/soma console` step, same as the session smoke test — the merge gate does
   not build a release, so it cannot run.

Then the consistency test changes. The `rebar.config` set and the doc bullet set
both gain `soma_actor`, so `test_doc_app_list_matches_rebar_release` keeps
passing on its own — the two sets stay equal. The test that asserted the doc says
"not yet bundled" can no longer hold, because criterion 3 deletes that phrase.

On the open question: I am replacing `test_doc_states_actor_not_bundled` with a
test that asserts the opposite — `soma_actor` is a member of both the
`rebar.config` release set and the `docs/release.md` bundled set. That covers
criterion 4 directly and keeps the suite honest. Keeping the old function and
inverting its body would leave a function named `..._not_bundled` asserting the
app *is* bundled, which would read as a lie. So the function is renamed.

The smoke-test command in the doc is documentation, not a gated test. The actor
boot path it documents is already proven inside the gate by
`soma_actor_startup_SUITE`, which boots the actor app alone and runs a one-step
`echo` envelope to `completed`. The doc command is the same shape run by hand
against an unpacked release.

## Acceptance criteria → tests

### Criterion 1 — rebar.config release list includes soma_actor
- Call chain: none (direct source-file read). The test consults `rebar.config`,
  pulls the relx release app list, and checks membership.
- Test entry: `soma_release_app_list_tests` reads `rebar.config` directly through
  `file:consult/1`; there is no caller path because the artifact under test is a
  config file, not running code.
- Test: `test_actor_bundled_in_rebar_and_doc` in
  `apps/soma_tools/test/soma_release_app_list_tests.erl`

### Criterion 2 — docs/release.md has a soma_actor bundled-app bullet
- Call chain: none (direct source-file read). The test reads `docs/release.md`
  and checks for the `` - `soma_actor` `` bullet shape.
- Test entry: `soma_release_app_list_tests` reads `docs/release.md` directly
  through `file:read_file/1`; the artifact under test is a doc file, not code.
- Test: `test_actor_bundled_in_rebar_and_doc` in
  `apps/soma_tools/test/soma_release_app_list_tests.erl`

### Criterion 3 — docs/release.md no longer contains "not yet bundled"
- Call chain: none (direct source-file read). The test reads `docs/release.md`
  and asserts the phrase is absent from the whole file.
- Test entry: `soma_release_app_list_tests` reads `docs/release.md` directly; the
  artifact is a doc file.
- Test: `test_doc_drops_not_yet_bundled` in
  `apps/soma_tools/test/soma_release_app_list_tests.erl`

### Criterion 4 — test asserts soma_actor is in both sets
- Call chain: none (compile-time / config-and-doc assertion). The test derives
  the `rebar.config` release set and the `docs/release.md` bundled set, then
  asserts `soma_actor` is a member of each.
- Test entry: `soma_release_app_list_tests` reads both files directly; no running
  code is exercised.
- Test: `test_actor_bundled_in_rebar_and_doc` in
  `apps/soma_tools/test/soma_release_app_list_tests.erl`

### Criterion 5 — test still fails when the two lists name different app sets
- Call chain: none (direct source-file read). The existing equality test compares
  the full `rebar.config` release set against the full `docs/release.md` bundled
  set, so any mismatch in either direction is caught.
- Test entry: `soma_release_app_list_tests` reads both files directly. The "still
  fails on drift" guarantee is the equality assertion itself — introduce drift in
  either file and `?assertEqual` goes red.
- Test: `test_doc_app_list_matches_rebar_release` in
  `apps/soma_tools/test/soma_release_app_list_tests.erl`

### Criterion 6 — docs/release.md documents a runnable actor boot smoke test
- Call chain: none (direct source-file read). The doc check asserts the smoke
  test section names `soma_actor_sup:start_actor`, an `echo` step, and the
  `completed` terminal status.
- Test entry: `soma_release_app_list_tests` reads `docs/release.md` directly. The
  documented command's behavior — start actor, run one `echo` step, reach
  `completed` — is the same path the gated suite already proves, but the doc text
  itself is what this criterion adds, so the test checks the doc text.
- Test: `test_doc_has_actor_smoke_test` in
  `apps/soma_tools/test/soma_release_app_list_tests.erl`
- Backing proof that the documented path works (already green, not added here):
  `actor_only_start_runs_steps_to_terminal` in
  `apps/soma_actor/test/soma_actor_startup_SUITE.erl` — boots the actor app
  alone, sends a one-step `echo` envelope, and waits for task status `completed`.

### Criterion 7 — rebar3 eunit && rebar3 ct green at HEAD
- Call chain: the full gate. `rebar3 eunit` runs every EUnit module including the
  edited `soma_release_app_list_tests`; `rebar3 ct` runs every CT suite including
  `soma_actor_startup_SUITE` and the release-packaging suites.
- Test entry: the merge gate runs both commands; no single test owns this — it is
  the whole suite passing.
- Test: whole-suite green (`rebar3 eunit && rebar3 ct`)

## Risks & trade-offs

The doc smoke test is not run by the gate. It is a copy-paste command a human
runs against an unpacked release, and nothing checks that the command stays
correct as the actor API changes. This is the same gap the session smoke test
already has, and the gated `soma_actor_startup_SUITE` runs the same boot-and-run
path in code, so a real regression in that path turns the gate red even though
the doc command itself is unchecked. The exposure is narrow: the doc command
could rot (wrong function name, wrong arg shape) without any test noticing.

Renaming `test_doc_states_actor_not_bundled` drops a test name that someone might
grep for. The function is replaced by two tests with clearer names covering the
inverted behavior, so the coverage moves, not shrinks. Anyone looking for the old
name will find the bundled-app tests next to it in the same file.

Adding `soma_actor` to the release list grows the boot set: starting the packaged
release now boots the actor app's supervisor too. The actor supervisor is
`simple_one_for_one` with no children at boot, so this adds one idle supervisor
process and no behavior change to the runtime core. The risk is essentially the
cost of one extra supervisor in the tree.
