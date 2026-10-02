# Live capture permissions

The application runs as your normal user. The capture helper opens the capture device, drops supplementary groups and both real and effective group/user IDs, and writes pcapng to stdout. The interpreter, helper, libraries, gems, and every parent directory of the privileged wrapper must be owned by root and must not be writable by group or other users.

On macOS, grant the intended capture group access to `/dev/bpf*` using an administrator-managed startup configuration. Once `vanken-capture --check --interface lo0` reports `"direct":true`, Vanken can capture without sudo. Device permissions may need to be restored after a reboot.

For Linux, an administrator can install an isolated Ruby runtime and the required redhound gem under a root-owned prefix, copy `lib/` and `exe/vanken-capture` into `/usr/local/libexec/vanken/`, and install this fixed-path wrapper. Replace the runtime and gem paths below with the actual root-owned installation paths:

```sh
#!/bin/sh
exec /usr/bin/env -i PATH=/usr/bin:/bin \
  GEM_HOME=/opt/vanken-ruby/gems GEM_PATH=/opt/vanken-ruby/gems \
  /opt/vanken-ruby/bin/ruby -I /usr/local/libexec/vanken/lib \
  /usr/local/libexec/vanken/helper "$@"
```

Save it as `/usr/local/libexec/vanken/vanken-capture`, owned by root with mode `0755`. The executable saved as `helper` is the packaged `exe/vanken-capture`; `lib/` is the packaged Ruby library directory. Install redhound `2.0.0.rc2` and the runtime's standard-library gems in the isolated gem directory. Keep this tree separate from development checkouts, user gem homes, rbenv installations owned by users, and plugins.

An administrator may grant a dedicated capture group access through sudoers:

```sudoers
%vanken ALL=(root) NOPASSWD: /usr/local/libexec/vanken/vanken-capture
```

Validate the rule with `visudo`. Members of this group can capture network traffic. Vanken supplies `--drop-to UID:GID` for the invoking user and only invokes the fixed wrapper through sudo or pkexec. A polkit policy must likewise allow that fixed path; an optional askpass helper must meet the same ownership requirements. Vanken rejects elevation of a development checkout and does not grant capabilities to a general-purpose Ruby interpreter.

`vanken-capture --list-interfaces` lists interfaces without elevated privileges. `vanken-capture --check --interface IF` checks direct device access. A helper invoked manually with sudo needs `--drop-to` because the wrapper clears the environment:

```sh
sudo /usr/local/libexec/vanken/vanken-capture -i eth0 --drop-to "$(id -u):$(id -g)" > capture.pcapng
```

For the isolated Linux integration check, run `script/capture-ci.sh` with Docker available. It creates a disposable privileged container, installs root-owned Ruby/gems and the fixed helper wrapper, creates the `vanken-test` namespace and a veth pair, then runs the tests as an unprivileged user. The tests verify UID dropping, packet capture, statistics, and clean shutdown. The nightly `Live capture` workflow runs this same command.
