# [cc] v0.2: document and package sample CLI tools in releases

## Current state

The `cli` adapter is built and hardened. `soma_tool_call:run/1` has a branch
that opens a port on `{spawn_executable, Executable}` with an argv list, no
shell. A `cli` manifest carries `executable` (a path string) and `argv`. The
manifest validator (`soma_tool_manifest`) and the registry
(`soma_tool_registry`) accept and store that shape. The five CLI CT suites in
`apps/soma_runtime/test/` exercise the adapter end to end.

Every one of those suites writes its helper script to a fresh temp directory at
test time and points `executable` at that absolute temp path. Nothing in the
repo commits a helper, and nothing resolves `executable` from a release-relative
location. So the repo proves the adapter launches a program, but it does not
prove the packaging convention the design calls for: where a shipped helper
lives in a release, and how a tool names it without baking in an absolute build
path.

`docs/release.md` covers packaging the OTP apps and ERTS into a self-contained
tarball. It says nothing about external helper executables — not where they sit
in an unpacked release, not how a tool points at one, not the per-architecture
rule.

`apps/soma_tools/` has no `priv/` directory today. A `prod` release built now
produces `lib/soma_tools-0.1.0/` with only `ebin` and `src`.

## Approach

Commit one sample helper as a `#!/bin/sh` script at
`apps/soma_tools/priv/cli/soma_sample_upper`. It uppercases its last argv
argument and prints the result to stdout — the same transform the existing
`write_cli_helper/0` test helper uses, so it slots into the adapter's argv input
protocol with no adapter change. `soma_tools` owns it because tools live in that
app and the app is already in the release. A shell script runs on a machine with
no Erlang, and it is not an escript, so it satisfies the "self-contained, runs
without Erlang" criterion. It is the same portable script on all three target
architectures.

The tool names the helper by resolving `code:priv_dir(soma_tools)` at
registration time and joining the relative path `"cli/soma_sample_upper"`. That
is the release-relative convention: `code:priv_dir/1` returns the loaded app's
`priv` directory wherever the app is loaded from — out of `_build` during tests,
out of `lib/soma_tools-<vsn>/priv` in an unpacked release. The manifest still
stores an absolute `executable` string (the adapter contract is unchanged); the
point is that the absolute string is computed at runtime from `priv_dir`, not
typed in at a build path.

Standard rebar3/relx packaging carries `apps/soma_tools/priv` into the release
as `lib/soma_tools-<vsn>/priv` with no overlay config. The release built today
has no `priv` because the directory does not exist yet; adding the directory is
what makes it appear. So the release-packaging criterion needs the committed
helper plus a confirmation that relx copied it, not a config change.

The per-architecture rule is documentation, not three binaries. The committed
sample is one portable script. `docs/release.md` writes down the rule a real
compiled helper would follow: one helper artifact per target architecture
(macOS arm64, Linux x86_64, Linux arm64), and a build on one host carries only
that host's helper. This matches the existing "release is built per host
architecture" framing already in the file.

### On the "runnable in an unpacked release" tests

Two criteria ask for a test that the helper is resolvable through
`code:priv_dir/1` and runnable in place from an assembled release. A Common Test
run loads `soma_tools` out of `_build/test/lib/soma_tools`, not out of a `prod`
release tarball. So a CT case cannot, by itself, stand inside a booted release.

The honest split is:

- The CT proves the convention works in any loaded context: it resolves the
  helper through `code:priv_dir(soma_tools)`, asserts the file is there and
  executable, and drives a real run through the adapter using that resolved
  path. This is the part that must stay green in the suite gate.
- The assembled-release-in-place check is a shell smoke test against
  `_build/prod/rel/soma/lib/soma_tools-<vsn>/priv/cli/soma_sample_upper`,
  documented in `docs/release.md` as a command an operator runs against an
  unpacked release. It is not a CT case, because the suite does not build or
  boot a `prod` release.

The CT carries the `code:priv_dir/1` resolution proof for both criteria; the
release smoke-test command carries the "in an actual unpacked release" proof.
The Risks section names this gap plainly.

## Acceptance criteria → tests

### Criterion 1 — sample helper committed under priv at a documented location
- Call chain: none (direct source-file read)
- Test entry: the test reads `apps/soma_tools/priv/cli/soma_sample_upper` off
  disk and checks it exists and has the executable bit; the committed file and
  the doc location are the deliverable, not a runtime path.
- Test: `test_sample_helper_committed_and_executable` in
  `apps/soma_tools/test/soma_sample_cli_tests.erl`

### Criterion 2 — helper runs with no Erlang installed
- Call chain: none (direct source-file read)
- Test entry: the test reads the helper's first line and asserts it is a
  `#!/bin/sh` shebang and the file is not an escript. A shell script with a
  shebang runs from a plain shell with no Erlang; asserting the shebang and the
  absence of an escript header is what pins "self-contained, not an escript" in
  the suite. The genuine no-Erlang execution is covered by the release smoke
  test in `docs/release.md` (Criterion 8).
- Test: `test_sample_helper_is_shell_script_not_escript` in
  `apps/soma_tools/test/soma_sample_cli_tests.erl`

### Criterion 3 — committed helper drives a real run to run.completed with its stdout as the step output
- Call chain: test resolves `code:priv_dir(soma_tools)` →
  `soma_tool_registry:register_tool` (cli manifest, `executable` = resolved
  priv path) → `soma_agent_session:start_link` →
  `soma_agent_session:start_run` → `soma_run` step cursor →
  `soma_tool_call` cli branch → `open_port({spawn_executable, ...})` →
  helper runs → `run.completed` with the helper's stdout as the step output
- Test entry: `soma_agent_session:start_run` (no layer bypassed; the test
  starts at the live session entry point the same way the existing cli adapter
  suite does)
- Test: `test_priv_helper_run_reaches_completed_with_stdout` in
  `apps/soma_runtime/test/soma_cli_packaging_SUITE.erl`

### Criterion 4 — helper carried into the release by priv packaging, resolvable and runnable in place
- Call chain: test resolves `code:priv_dir(soma_tools)` → joins
  `"cli/soma_sample_upper"` → `open_port({spawn_executable, ...})` on the
  resolved path directly
- Test entry: `code:priv_dir(soma_tools)`. The test enters at the resolution
  function rather than at the session layer because the criterion is about the
  packaging path being resolvable and the file being runnable in place, not
  about the run machinery (Criterion 3 already covers the full run). It asserts
  the resolved path is under the loaded app's `priv`, the helper is there, and
  spawning it returns the expected stdout. The "assembled `prod` release"
  variant of this is the documented smoke test (Criterion 8), since a CT run
  loads the app from `_build`, not from a release tarball.
- Test: `test_priv_helper_resolvable_and_runnable_in_place` in
  `apps/soma_runtime/test/soma_cli_packaging_SUITE.erl`

### Criterion 5 — release.md documents the release-relative location of a packaged helper
- Call chain: none (direct source-file read)
- Test entry: the test reads `docs/release.md` and asserts it names the
  `lib/soma_tools-<vsn>/priv/...` location for a packaged CLI helper.
- Test: `test_release_doc_states_priv_location` in
  `apps/soma_tools/test/soma_release_doc_tests.erl`

### Criterion 6 — release.md documents naming the executable by a priv_dir-resolved relative path
- Call chain: none (direct source-file read)
- Test entry: the test reads `docs/release.md` and asserts it states a tool
  names its packaged executable through `code:priv_dir/1` rather than an
  absolute build path.
- Test: `test_release_doc_states_priv_dir_convention` in
  `apps/soma_tools/test/soma_release_doc_tests.erl`

### Criterion 7 — release.md documents the per-architecture packaging rule
- Call chain: none (direct source-file read)
- Test entry: the test reads `docs/release.md` and asserts it names all three
  targets (macOS arm64, Linux x86_64, Linux arm64) and states a build on one
  architecture carries only that architecture's helper.
- Test: `test_release_doc_states_per_architecture_rule` in
  `apps/soma_tools/test/soma_release_doc_tests.erl`

### Criterion 8 — release.md includes a smoke-test command for the packaged helper
- Call chain: none (direct source-file read)
- Test entry: the test reads `docs/release.md` and asserts it contains a smoke
  command that runs the packaged helper from an unpacked release (a command
  invoking the helper under
  `_build/prod/rel/soma/lib/soma_tools-<vsn>/priv/...`).
- Test: `test_release_doc_has_helper_smoke_command` in
  `apps/soma_tools/test/soma_release_doc_tests.erl`

### Criterion 9 — existing soma_runtime and soma_tools suites stay green
- Call chain: none (the whole EUnit + CT gate)
- Test entry: the relay merge gate runs `rebar3 eunit && rebar3 ct`. No new
  test asserts this; it is the standing gate. Adding the `priv/` directory and
  the new suites must not break the existing CLI suites or the manifest/registry
  unit tests.
- Test: existing suites under `apps/soma_runtime/test/` and
  `apps/soma_tools/test/`, run by the gate.

## Risks & trade-offs

The sample is a shell script, so it proves the packaging convention but not the
per-architecture binary story. Two CT criteria (4) and one doc criterion (7)
lean on the documented rule for a real compiled helper. That gap is exactly what
the issue's Out of scope section accepts: cross-compiling three binaries from
one host is not in this issue. The design does not pretend a portable script
exercises the per-architecture path; it documents the rule and ships one sample.

A CT run loads `soma_tools` from `_build/test`, not from a `prod` release
tarball. So Criterion 4's CT case proves "resolvable through `code:priv_dir/1`
and runnable in place" in the test context, not literally inside a booted
release. The literal in-release proof is the documented smoke-test command an
operator runs against the unpacked tarball (Criterion 8). Splitting it this way
keeps the suite gate fast and avoids building and booting a `prod` release
inside CT, at the cost of the strongest possible proof being a manual command
rather than an automated assertion.

The helper depends on `/bin/sh` and the shell builtins `printf` and `tr` being
on the child's `PATH`. The adapter already passes the runtime's `PATH` through
in its minimal env for exactly this reason, so the dependency is consistent with
how the existing CLI suites' helpers run. A target with no `/bin/sh` would not
run this sample — acceptable for a v0.1 sample, and the reason the per-arch rule
in the docs is written for a compiled helper, which has no such dependency.
