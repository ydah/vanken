# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Check Ruby code for lint errors"
task :lint do
  sh "bundle exec rubocop --lint --no-parallel"
end

desc "Generate inline type signatures"
task :rbs do
  sh "bundle exec rbs-inline --opt-out --output lib/vanken"
end

desc "Validate signatures and type-check Core and Gateway"
task :steep do
  sh "bundle exec rbs validate"
  sh "bundle exec steep check -j 2"
end

task default: %i[spec lint steep]
