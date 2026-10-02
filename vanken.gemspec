# frozen_string_literal: true

require_relative "lib/vanken/version"

Gem::Specification.new do |spec|
  spec.name = "vanken"
  spec.version = Vanken::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "A pure Ruby graphical packet capture and analysis tool"
  spec.description = "Inspect pcap and pcapng captures with a virtual packet list, protocol details, byte view, and display filters."
  spec.homepage = "https://github.com/ydah/vanken"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) { Dir["{lib,exe,sig,data,packaging,docs}/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md"].select { |path| File.file?(path) } }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "redhound", "2.0.0.rc2"
  spec.add_dependency "zaniah", "~> 0.12.4"
  spec.add_dependency "fiddle", "~> 1.1"

end
