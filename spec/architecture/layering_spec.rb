# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Library boundaries" do
  it "keeps packet analysis and rendering libraries inside their adapters" do
    Dir[File.expand_path("../../lib/**/*.rb", __dir__)].each do |path|
      source = File.read(path)
      next if path.include?("/gateway/") || path.match?(%r{/capture/helper_})
      expect(source).not_to match(/\bRedhound(?:::|\.)/), path
      next if path.include?("/ui/")
      expect(source).not_to match(/\bZaniah(?:::|\.)/), path
    end
  end
end
