# Releases

## Release policy

Work is committed on main. Release notes and CHANGELOG entries include only user-visible changes. Documentation and maintenance changes alone do not trigger a release.

## Verify a version

Before tagging, run `bundle exec rake`, verify generated RBS is current, run privileged capture and benchmarks, perform native smoke, and build the gem strictly. Version, tag, gemspec dependencies, and lockfile must agree. Exclude captures, spools, test artifacts, local dependencies, and credentials from the gem.

## Publish with trusted publishing

Initial 0.1.0 notes are exactly `Initial release.`. Its owner publication and trusted publishing setup are complete. The job skips uploading a version already present on RubyGems.

Subsequent `vX.Y.Z` tags trigger `.github/workflows/release.yml`, based on the Canopus release job. It verifies version, runs checks, builds the gem, publishes with RubyGems trusted publishing, and creates GitHub release notes from CHANGELOG.

Trusted publisher identity: owner `ydah`, repository `vanken`, workflow `release.yml`, GitHub environment `release`.

## Version milestones

The design milestones are 0.1 for file inspection, capture, and filters; 0.2 for coloring, search, stream following, statistics, and analysis extensions; and 0.3 for profiles, localization, permission packaging, recovery UI, and additional capture conveniences. Some 0.3 foundations are included with 0.2 so analysis extensions can share profiles and settings. The 0.3 release completes the administrator setup command and includes permission packaging as downloadable release assets.
