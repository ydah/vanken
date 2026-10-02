# frozen_string_literal: true

require "cgi"
require "erb"
require "fileutils"
require "pathname"
require "rdoc"
require "rdoc/markdown"
require "rdoc/markup/to_html"

ROOT = File.expand_path("..", __dir__)
OUTPUT = File.join(ROOT, "tmp/site")
CHECK = ARGV.include?("--check")

def h(value) = CGI.escapeHTML(value.to_s)
def relative(from, to) = Pathname.new(to).relative_path_from(Pathname.new(from).dirname).to_s

pages = [
  {source: "docs/getting-started.md", path: "docs/index.html", title: "Getting started", group: "Using Vanken", lead: "Install Vanken, open a capture, and inspect your first packet."},
  {source: "docs/usage.md", path: "docs/usage.html", title: "User guide", group: "Using Vanken", lead: "Inspect packets, follow streams, export results, and make the workspace your own."},
  {source: "docs/filters.md", path: "docs/filters.html", title: "Display filters", group: "Using Vanken", lead: "Find traffic with protocol fields, addresses, expressions, and typed values."},
  {source: "packaging/README.md", path: "docs/capture-permissions.html", title: "Capture permissions", group: "Using Vanken", lead: "Set up Linux or macOS capture access while running Vanken as your regular user."},
  {source: "docs/performance.md", path: "docs/performance.html", title: "Measurements and limits", group: "Reference", lead: "Recorded workloads, measurement boundaries, and current performance constraints."},
  {source: "docs/upstream.md", path: "docs/development.html", title: "Development", group: "Reference", lead: "Dependencies, upstream contracts, and component integration."},
  {source: "docs/releases.md", path: "docs/releases.html", title: "Releases", group: "Reference", lead: "How Vanken versions are checked, packaged, and published."}
]
destinations = pages.to_h { |page| [page[:source], page[:path]] }.merge("README.md" => "index.html")
template = ERB.new(File.read(File.join(ROOT, "docs/_templates/page.erb")), trim_mode: "-")
html_pages = {"index.html" => File.read(File.join(ROOT, "index.html"))}

pages.each_with_index do |page, index|
  source = File.read(File.join(ROOT, page[:source]), encoding: Encoding::UTF_8).sub(/\A# [^\n]+\n+/, "")
  renderer = RDoc::Markup::ToHtml.new
  content = renderer.convert(RDoc::Markdown.parse(source))
  content = content.gsub(/(href|src)="([^"]+)"/) do
    attribute, href = Regexp.last_match.captures
    target, fragment = CGI.unescapeHTML(href).split("#", 2)
    if target.empty? || target.match?(/\A[a-z][a-z0-9+.-]*:/i)
      next "#{attribute}=\"#{h(CGI.unescapeHTML(href))}\""
    end
    original = target.sub(/_md\.html\z/, ".md")
    source_path = Pathname.new(File.join(File.dirname(page[:source]), original)).cleanpath.to_s
    if destinations.key?(source_path)
      target = relative(page[:path], destinations.fetch(source_path))
    elsif source_path.start_with?("docs/media/")
      target = relative(page[:path], source_path)
    else
      abort "Missing documentation link: #{page[:source]}: #{href}" unless File.file?(File.join(ROOT, source_path))
      target = "https://github.com/ydah/vanken/blob/main/#{source_path}"
    end
    "#{attribute}=\"#{h(target)}#{"##{h(fragment)}" if fragment}\""
  end
  headings = content.scan(/<h2 id="([^"]+)"[^>]*>(.*?)<\/h2>/m).map do |anchor, title|
    [anchor, CGI.unescapeHTML(title.gsub(/<[^>]*>/, ""))]
  end
  previous_page = pages[index - 1] if index.positive?
  next_page = pages[index + 1]
  html_pages[page[:path]] = template.result(binding).gsub(/[ \t]+$/, "")
end

# Check the generated navigation, fragments, and media without a web server.
html_pages.each do |path, html|
  html.scan(/(?:href|src)="([^"]+)"/).flatten.each do |href|
    next if href.match?(/\A[a-z][a-z0-9+.-]*:/i)
    target, fragment = CGI.unescapeHTML(href).split("#", 2)
    destination = target.empty? ? path : Pathname.new(File.join(File.dirname(path), target)).cleanpath.to_s
    destination = Pathname.new(File.join(destination, "index.html")).cleanpath.to_s if target.end_with?("/")
    if html_pages.key?(destination)
      if fragment && !html_pages.fetch(destination).scan(/id="([^"]+)"/).flatten.include?(fragment)
        abort "Missing page anchor: #{path}: #{href}"
      end
    else
      abort "Missing site asset: #{path}: #{href}" unless File.file?(File.join(ROOT, destination))
    end
  end
end

unless CHECK
  html_pages.each do |path, html|
    output = File.join(OUTPUT, path)
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, html)
  end
  FileUtils.cp(File.join(ROOT, "site.css"), OUTPUT)
  %w[assets/fonts docs/media].each do |directory|
    FileUtils.mkdir_p(File.join(OUTPUT, File.dirname(directory)))
    FileUtils.cp_r(File.join(ROOT, directory), File.join(OUTPUT, File.dirname(directory)))
  end
  File.write(File.join(OUTPUT, ".nojekyll"), "")
end
puts "docs: #{html_pages.size} pages #{CHECK ? 'valid' : "built in #{OUTPUT}"}"
