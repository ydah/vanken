# Development

## Set up a checkout

Use Ruby 3.3 or newer and the [desktop dependencies](getting-started.md#install-and-launch) for your platform.

```sh
git clone https://github.com/ydah/vanken.git
cd vanken
bundle install
bundle exec ruby script/generate_fixtures.rb --output tmp/fixtures
bundle exec exe/vanken tmp/fixtures/network.pcapng
```

The command writes small synthetic captures under `tmp/fixtures`; without `--output`, the generator uses `spec/fixtures/pcap`. Add `--performance` to generate a larger capture. To use a sibling Zaniah checkout, set `VANKEN_ZANIAH_PATH=../zaniah` when installing and running the bundle. Unset it to check against the published dependencies in [vanken.gemspec](../vanken.gemspec).

## Run checks

```sh
bundle exec rake
bundle exec rake rbs
git diff -- sig
gem build --strict vanken.gemspec
```

`rake` runs specs, Ruby lint, type checks, and documentation link checks. Regenerate signatures after changing inline types and review the resulting diff. Strict gem builds require RubyGems 4.0.16 or newer for the pinned redhound prerelease.

Use `bundle exec rspec PATH` to run the affected specs while iterating. [Contract specs](https://github.com/ydah/vanken/tree/main/spec/contract) cover dependency integration; [integration specs](https://github.com/ydah/vanken/tree/main/spec/integration) cover document lifecycle and cross-component behavior. The [architecture spec](https://github.com/ydah/vanken/blob/main/spec/architecture/layering_spec.rb) checks library boundaries. Live capture tests require the isolated Linux environment described below.

## Find the right layer

| Directory | Responsibility |
| --- | --- |
| `lib/vanken/core` | Frames, disk-backed stores, coloring, and display-filter parsing and evaluation. |
| `lib/vanken/gateway` | redhound adapters for dissection, file formats, capture, streams, and statistics. |
| `lib/vanken/capture` | Capture helper, privilege checks, reception, analyzer process, and filter workers. |
| `lib/vanken/app` | Document lifecycle, analysis jobs, navigation, search, and statistics. |
| `lib/vanken/ui` | Zaniah views, actions, dialogs, and asynchronous UI updates. |
| `lib/vanken/config` | Profiles, preferences, sessions, and safe configuration persistence. |

Keep redhound calls inside Gateway or the capture helper, and Zaniah calls inside UI. Update adapters and contract specs together when upgrading dependencies.

Preserve these behaviors when changing the pipeline:

- Reception writes original frames to a private disk spool; an unprivileged analyzer processes them in order. A filter change must not repeat stateful analysis.
- UI callbacks stay responsive by scheduling row reads, dissection, scans, and saves in background jobs. Cancellation and generation checks prevent old jobs from replacing newer results.
- Reassembled fields are logical data. Their offsets must not highlight unrelated bytes in the original frame.
- Saving retains all durable packets, including the unanalyzed tail. Exports use the requested analyzed set and replace their destination only after completion.
- Spool directories use mode 0700 and files 0600. Recovery rejects unsafe paths. Privileged capture uses a root-owned wrapper and strips Ruby startup injection from its environment; see [capture permissions](../packaging/README.md).

Dissector plugins use redhound's public `Redhound::Dissector` API and a separate registry for each document. [Plugin isolation specs](https://github.com/ydah/vanken/blob/main/spec/contract/plugin_isolation_spec.rb) include a working plugin and check registration, reload, summaries, filters, and concurrent sessions.

## Measure performance and capture behavior

```sh
bundle exec ruby --yjit script/benchmark.rb 1000000 120 4
bundle exec ruby --yjit script/filter-performance.rb 20000
bundle exec ruby --yjit script/analysis-performance.rb
bundle exec ruby --yjit script/native-smoke.rb
script/capture-ci.sh
```

The main benchmark arguments are packet count, UI samples, and slow-filter worker count; zero workers skips the slow filter. Native smoke needs a graphical session. `capture-ci.sh` needs Docker with Linux containers and runs a privileged, isolated network-namespace test as an ordinary application user. Reports go under `tmp/capture-results`; the default traffic run lasts 300 seconds at 5,000 packets/s. Set `CAPTURE_DURATION` and `CAPTURE_RATE` for shorter development runs.

Functional checks validate packet counts and raise on failures. Numeric performance targets are reported separately: a successful job does not mean every target passed. Compare repeated runs on the same host, Ruby, dependencies, packet mix, and settings.

Retained Ruby heap is not RSS. The benchmark reports parent RSS and sampled parent-plus-analyzer RSS separately; filter-worker RSS and filesystem cache are excluded. Headless scene timing includes layout, text shaping, and accessibility, but excludes pixel rasterization, native events, and GPU presentation. Native smoke reports scene and total tick time. Check the actual source rate and dropped packets before interpreting a growing-capture result. See [performance and limits](performance.md) for practical user guidance.

## Maintain documentation

The website renders these Markdown guides with RDoc and [tools/doc_page.erb](https://github.com/ydah/vanken/blob/main/tools/doc_page.erb). Page titles and navigation live in [tools/build_docs.rb](https://github.com/ydah/vanken/blob/main/tools/build_docs.rb); the landing page and styles are `index.html` and `site.css`.

```sh
bundle exec rake docs:check
bundle exec rake docs:build
python3 -m http.server 8000 --directory tmp/site
```

Open `http://localhost:8000` to preview the site. Builds replace the generated `tmp/site` directory. The Pages workflow checks and deploys documentation changes pushed to `main`. Update the application screenshot with `bundle exec ruby -Ilib tools/generate_overview.rb`; it renders the actual interface using synthetic traffic and documentation addresses.
