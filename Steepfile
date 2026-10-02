target :core do
  signature "sig"
  ignore_signature "sig/generated/vanken/ui"
  signature Pathname.new(File.join(Gem::Specification.find_by_name("redhound").full_gem_path, "sig")).relative_path_from(Pathname.pwd).to_s
  library "json", "strscan", "ipaddr", "tmpdir", "fileutils", "time", "logger", "yaml", "stringio", "optparse", "socket"
  check "lib/vanken/core"
  check "lib/vanken/gateway"
end
