#!/bin/sh
set -eu

if [ "${1:-}" != --inside ]; then
  capture_project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  capture_report_dir=${VANKEN_CAPTURE_REPORTS:-$capture_project_dir/tmp/capture-results}
  mkdir -p "$capture_report_dir"
  capture_run_dir=$(mktemp -d "$capture_report_dir/run-XXXXXX")
  exec docker run --rm --privileged \
    --mount "type=bind,source=$capture_project_dir,target=/workspace,readonly" \
    --mount "type=bind,source=$capture_run_dir,target=/reports" \
    --env "CAPTURE_DURATION=${CAPTURE_DURATION:-300}" \
    --env "CAPTURE_RATE=${CAPTURE_RATE:-5000}" \
    --env "CAPTURE_FILE_BYTES=${CAPTURE_FILE_BYTES:-100000000}" \
    ruby:3.4-bookworm /bin/sh /workspace/script/capture-ci.sh --inside
fi

[ "$(id -u)" = 0 ] || { echo "Container setup requires root." >&2; exit 1; }
apt-get update
apt-get install -y --no-install-recommends iproute2 iputils-ping sudo fonts-dejavu-core fonts-noto-cjk libvulkan1
gem install --no-document redhound --version 2.0.0.rc2
gem install --no-document rspec --version '~> 3.13'
gem install --no-document zaniah --version '~> 0.12.4'
gem install --no-document fiddle --version '~> 1.1'

install -d -m 0755 /opt/vanken-tests
cp -R /workspace/lib /workspace/spec /workspace/exe /workspace/script /workspace/packaging /workspace/data /workspace/.rspec /opt/vanken-tests/
chown -R root:root /opt/vanken-tests /usr/local
chmod -R go-w /opt/vanken-tests /usr/local
useradd --create-home --uid 1000 --user-group vanken-ci
chown vanken-ci:vanken-ci /reports
chmod 0755 /reports
/usr/local/bin/ruby -I/opt/vanken-tests/lib /opt/vanken-tests/exe/vanken-setup-permissions \
  --platform linux --ruby /usr/local/bin/ruby --gem-home /usr/local/bundle \
  --policy sudoers --group vanken-ci > /reports/permission-install.json
cp -R /opt/vanken-tests /home/vanken-ci/tests
chown -R vanken-ci:vanken-ci /home/vanken-ci/tests

capture_sender_pid=
cleanup() {
  if [ -n "$capture_sender_pid" ]; then
    kill "$capture_sender_pid" 2>/dev/null || true
    wait "$capture_sender_pid" 2>/dev/null || true
  fi
  /opt/vanken-tests/script/netns-teardown.sh
}
trap cleanup EXIT
/opt/vanken-tests/script/netns-setup.sh
cd /home/vanken-ci/tests
runuser -u vanken-ci -- env VANKEN_NETNS=1 GEM_HOME=/usr/local/bundle GEM_PATH=/usr/local/bundle:/usr/local/lib/ruby/gems/3.4.0 \
  /usr/local/bin/ruby -Ilib -S rspec spec/unit/capture spec/unit/capture_controller_spec.rb \
  spec/contract/capture_spec.rb spec/integration/capture_spec.rb spec/integration/permission_install_spec.rb spec/integration/tui_spec.rb spec/unit/capture_performance_spec.rb
runuser -u vanken-ci -- env VANKEN_TUI_REPORTS=/reports/tui VANKEN_TUI_CAPTURE_INTERFACE=vkn-host \
  GEM_HOME=/usr/local/bundle GEM_PATH=/usr/local/bundle:/usr/local/lib/ruby/gems/3.4.0 \
  /usr/local/bin/ruby --yjit -Ilib script/tui-smoke.rb

export VANKEN_CAPTURE_REPORTS=/reports
ip netns exec vanken-test /usr/local/bin/ruby script/capture-performance.rb --send &
capture_sender_pid=$!
runuser -u vanken-ci -- env VANKEN_CAPTURE_REPORTS=/reports \
  "CAPTURE_DURATION=${CAPTURE_DURATION:-300}" "CAPTURE_RATE=${CAPTURE_RATE:-5000}" \
  "CAPTURE_FILE_BYTES=${CAPTURE_FILE_BYTES:-100000000}" \
  GEM_HOME=/usr/local/bundle GEM_PATH=/usr/local/bundle:/usr/local/lib/ruby/gems/3.4.0 \
  /usr/local/bin/ruby --yjit -Ilib script/capture-performance.rb
wait "$capture_sender_pid"
capture_sender_pid=
