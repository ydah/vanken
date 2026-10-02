# frozen_string_literal: true

require_relative "lib/vanken/version"

Gem::Specification.new do |spec|
  spec.name = "vanken"
  spec.version = Vanken::VERSION
  spec.authors = ["ydah"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "A pure Ruby graphical packet capture and analysis tool"
  spec.description = "Inspect pcap and pcapng captures with a virtual packet list, protocol details, byte view, and display filters."
  spec.homepage = "https://github.com/noxdea/vanken"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) { Dir["{lib,exe,sig,data,packaging}/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md"].select { |path| File.file?(path) } }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "redhound", "2.0.0.rc2"
  spec.add_dependency "zaniah", ">= 0.11.0", "< 0.13.0"
  spec.add_dependency "fiddle", "~> 1.1"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
