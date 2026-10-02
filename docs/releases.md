# Releases

Work is committed on main. Release notes and CHANGELOG entries include only user-visible changes. Documentation and maintenance changes alone do not trigger a release.

Before tagging, run `bundle exec rake`, verify generated RBS is current, run privileged capture and benchmarks, perform native smoke, and build the gem strictly. Version, tag, gemspec dependencies, and lockfile must agree. Exclude captures, spools, test artifacts, local dependencies, and credentials from the gem.

Initial 0.1.0 notes are exactly `Initial release.`. Publication is paused until the owner publishes the first RubyGem and configures trusted publishing. No initial release tag is pushed automatically.

For the first publication, run `gem push pkg/vanken-0.1.0.gem`, then configure the publisher identity below. Tagging `v0.1.0` afterwards runs validation and creates the GitHub release; the job skips uploading a version already present on RubyGems.

Subsequent `vX.Y.Z` tags trigger `.github/workflows/release.yml`, based on the Canopus release job. It verifies version, runs checks, builds the gem, publishes with RubyGems trusted publishing, and creates GitHub release notes from CHANGELOG.

Trusted publisher identity: owner `ydah`, repository `vanken`, workflow `release.yml`, GitHub environment `release`.

The design milestones are 0.1 for file inspection, capture, and filters; 0.2 for coloring, search, stream following, statistics, and analysis extensions; and 0.3 for profiles, localization, permission packaging, recovery UI, and additional capture conveniences. Work stops at the initial publication gate before the later milestones.
