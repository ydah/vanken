#!/bin/sh
set -eu

if [ "${1:-}" != --inside ]; then
  capture_project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  exec docker run --rm --privileged \
    --mount "type=bind,source=$capture_project_dir,target=/workspace,readonly" \
    ruby:3.4-bookworm /bin/sh /workspace/script/capture-ci.sh --inside
fi

[ "$(id -u)" = 0 ] || { echo "Container setup requires root." >&2; exit 1; }
apt-get update
apt-get install -y --no-install-recommends iproute2 iputils-ping sudo
gem install --no-document redhound --version 2.0.0.rc2
gem install --no-document rspec --version '~> 3.13'

install -d -m 0755 /opt/vanken-tests /usr/local/libexec/vanken
cp -R /workspace/lib /workspace/spec /workspace/exe /workspace/script /workspace/.rspec /opt/vanken-tests/
cp -R /opt/vanken-tests/lib /usr/local/libexec/vanken/lib
cp /opt/vanken-tests/exe/vanken-capture /usr/local/libexec/vanken/helper
cat > /usr/local/libexec/vanken/vanken-capture <<'WRAPPER'
#!/bin/sh
exec /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin \
  GEM_HOME=/usr/local/bundle GEM_PATH=/usr/local/bundle \
  /usr/local/bin/ruby -I /usr/local/libexec/vanken/lib \
  /usr/local/libexec/vanken/helper "$@"
WRAPPER
chmod 0755 /usr/local/libexec/vanken/vanken-capture
chown -R root:root /usr/local/libexec/vanken /usr/local/bundle
chmod -R go-w /usr/local/libexec/vanken /usr/local/bundle

useradd --create-home --uid 1000 --user-group vanken-ci
printf '%s\n' 'vanken-ci ALL=(root) NOPASSWD: /usr/local/libexec/vanken/vanken-capture' > /etc/sudoers.d/vanken-capture-ci
chmod 0440 /etc/sudoers.d/vanken-capture-ci
visudo -cf /etc/sudoers.d/vanken-capture-ci
cp -R /opt/vanken-tests /home/vanken-ci/tests
chown -R vanken-ci:vanken-ci /home/vanken-ci/tests

trap '/opt/vanken-tests/script/netns-teardown.sh' EXIT
/opt/vanken-tests/script/netns-setup.sh
cd /home/vanken-ci/tests
runuser -u vanken-ci -- env VANKEN_NETNS=1 GEM_HOME=/usr/local/bundle GEM_PATH=/usr/local/bundle \
  /usr/local/bin/ruby -Ilib -S rspec spec/unit/capture spec/unit/capture_controller_spec.rb \
  spec/contract/capture_spec.rb spec/integration/capture_spec.rb
