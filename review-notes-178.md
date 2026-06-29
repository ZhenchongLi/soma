### Claude

## Verdict

changes-requested

## Real issues

1. `site/test/polish-build-clean.sh:38` does not actually enforce the stated clean-build contract, and the contract fails in this checkout. The acceptance criterion says `cd site && npm ci && npm run build` must produce no error or warning lines. Running that exact command exits 0 but emits `npm warn ...` lines and a Node `DeprecationWarning`. The committed harness only scans `error|warning`, so it misses `npm warn` lines entirely and only fails here because the dependency stack emits `DeprecationWarning`. That leaves criterion 1 unmet and gives a false sense that the build-clean proof is complete.

## Questions

None.

## Nits

None.

## Functional evidence

- [x] `cd site && npm ci && npm run build` exits 0 with no error or warning lines in its output.

  Evidence from `cd site && npm ci && npm run build` captured to a log:

  ```text
  build_status=0
  1:npm warn Unknown user config "always-auth". This will stop working in the next major version of npm. See `npm help npmrc` for supported config options.
  7:npm warn allow-scripts 5 packages have install scripts not yet covered by allowScripts:
  70:(node:32049) [DEP0190] DeprecationWarning: Passing args to a child process with shell option true can lead to security vulnerabilities, as the arguments are not escaped, only concatenated.
  72:npm warn Unknown env config "always-auth". This will stop working in the next major version of npm. See `npm help npmrc` for supported config options.
  ```

  The branch harness also fails:

  ```text
  $ cd site && ./test/polish-build-clean.sh
  70:(node:29737) [DEP0190] DeprecationWarning: Passing args to a child process with shell option true can lead to security vulnerabilities, as the arguments are not escaped, only concatenated.
  71:(Use `node --trace-deprecation ...` to show where the warning was created)
  FAIL: Criterion 1 — build output contains error/warning line(s) (shown above)
  ```

- [x] `site/dist/404.html` exists after a build and contains a link whose href is `/`.

  ```text
  $ cd site && test -f dist/404.html && rg -n 'href="/"' dist/404.html
  2:... <a class="brand" href="/">Soma</a> ...
  5:... <a class="cta primary" href="/">Back home</a> ...
  ```

- [x] `site/dist/start/quick-start/index.html` exists after a build and contains the token `rebar3`.

  ```text
  $ cd site && test -f dist/start/quick-start/index.html && rg -n 'rebar3' dist/start/quick-start/index.html
  75:run from the shell. Everything below assumes Erlang/OTP 29 and rebar3 are on your
  80:... rebar3 ... compile ... rebar3 ... eunit ... rebar3 ... ct ...
  81:<p><code dir="auto">rebar3 ct</code> is the one that matters...
  86:... data-code="rebar3 shell" ...
  ```

- [x] The rendered docs sidebar links to `/start/quick-start/` inside the **Start Here** group (alongside the existing `/start/overview/` link).

  ```text
  $ cd site && perl -0ne 'if (/(Start Here.*?Quick start.*?<\/ul>)/s) { $s=$1; $s =~ s/\s+/ /g; print "$s\n" }' dist/concepts/architecture/index.html
  Start Here ... <a href="/" aria-current="false" ...>Home</a> ... <a href="/start/overview/" aria-current="false" ...>Overview</a> ... <a href="/start/quick-start/" aria-current="false" ...>Quick start</a> ...
  ```

- [x] The rendered docs sidebar contains a **Home** link whose href is `/`.

  ```text
  $ cd site && perl -0ne 'if (/(Start Here.*?Quick start.*?<\/ul>)/s) { $s=$1; $s =~ s/\s+/ /g; print "$s\n" }' dist/concepts/architecture/index.html
  Start Here ... <a href="/" aria-current="false" ...>Home</a> ... <a href="/start/overview/" aria-current="false" ...>Overview</a> ... <a href="/start/quick-start/" aria-current="false" ...>Quick start</a> ...
  ```

- [x] A built docs page (e.g. `site/dist/concepts/architecture/index.html`) contains a link to `https://github.com/ZhenchongLi/soma`.

  ```text
  $ cd site && perl -0ne 'while (/(<a href="https:\/\/github\.com\/ZhenchongLi\/soma"[^>]*>)/g) { print "$1\n" }' dist/concepts/architecture/index.html | sed -n '1,4p'
  <a href="https://github.com/ZhenchongLi/soma" rel="me" class="sl-flex astro-wy4te6ga">
  <a href="https://github.com/ZhenchongLi/soma" rel="me" class="sl-flex astro-wy4te6ga">
  ```

- [x] `site/dist/index.html` contains an `og:title` meta tag.

  ```text
  $ cd site && perl -0ne 'while (/(<meta (?:property|name)="(?:og:title|og:description|og:type|og:url|twitter:card)"[^>]*>)/g) { print "$1\n" }' dist/index.html
  <meta property="og:title" content="Soma — an Erlang/OTP-native agent runtime">
  ```

- [x] `site/dist/index.html` contains an `og:description` meta tag.

  ```text
  $ cd site && perl -0ne 'while (/(<meta (?:property|name)="(?:og:title|og:description|og:type|og:url|twitter:card)"[^>]*>)/g) { print "$1\n" }' dist/index.html
  <meta property="og:description" content="An Erlang/OTP-native agent runtime: an agent run is a supervised OTP process tree, not a function calling tools in a loop.">
  ```

- [x] `site/dist/index.html` contains an `og:type` meta tag with content `website`.

  ```text
  $ cd site && perl -0ne 'while (/(<meta (?:property|name)="(?:og:title|og:description|og:type|og:url|twitter:card)"[^>]*>)/g) { print "$1\n" }' dist/index.html
  <meta property="og:type" content="website">
  ```

- [x] `site/dist/index.html` contains an `og:url` meta tag with content `https://soma.fists.cc/`.

  ```text
  $ cd site && perl -0ne 'while (/(<meta (?:property|name)="(?:og:title|og:description|og:type|og:url|twitter:card)"[^>]*>)/g) { print "$1\n" }' dist/index.html
  <meta property="og:url" content="https://soma.fists.cc/">
  ```

- [x] `site/dist/index.html` contains a `twitter:card` meta tag with content `summary`.

  ```text
  $ cd site && perl -0ne 'while (/(<meta (?:property|name)="(?:og:title|og:description|og:type|og:url|twitter:card)"[^>]*>)/g) { print "$1\n" }' dist/index.html
  <meta name="twitter:card" content="summary">
  ```

- [x] After a build, every existing route still produces its HTML file: the landing `index.html`, `start/overview/`, all 8 `concepts/*`, all 4 `guides/*`, and both `reference/*`.

  ```text
  present dist/index.html
  present dist/start/overview/index.html
  present dist/concepts/actors/index.html
  present dist/concepts/architecture/index.html
  present dist/concepts/decision-layer/index.html
  present dist/concepts/durability/index.html
  present dist/concepts/events-and-trace/index.html
  present dist/concepts/resume/index.html
  present dist/concepts/steps/index.html
  present dist/concepts/tools/index.html
  present dist/guides/cli/index.html
  present dist/guides/lfe-dsl/index.html
  present dist/guides/release/index.html
  present dist/guides/usage/index.html
  present dist/reference/erlang-otp-primer/index.html
  present dist/reference/roadmap/index.html
  ```
