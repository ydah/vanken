# Live capture permissions

## Review the installation plan

`vanken-setup-permissions` installs the files shipped in `packaging/linux/` or `packaging/macos/`. Review the macOS plan first:

```sh
vanken-setup-permissions --platform darwin --dry-run
```

On Linux, provide the canonical absolute paths of a root-owned Ruby 3.3 or newer runtime and its isolated gem home:

```sh
vanken-setup-permissions --platform linux --dry-run \
  --ruby /opt/vanken-ruby/bin/ruby --gem-home /opt/vanken-ruby/gems
```

## Install on Linux

The following administrator installation assumes Ruby is already installed under `/opt/vanken-ruby`, with root-owned runtime files that are not writable by group or other users. Install Vanken into the isolated root-owned gem home, then run its packaged setup command with that same interpreter:

```sh
sudo /usr/bin/env -i PATH=/usr/bin:/bin GEM_HOME=/opt/vanken-ruby/gems GEM_PATH=/opt/vanken-ruby/gems \
  /opt/vanken-ruby/bin/ruby /opt/vanken-ruby/bin/gem install vanken --version 0.3.0 --no-document
sudo /usr/bin/env -i PATH=/usr/bin:/bin GEM_HOME=/opt/vanken-ruby/gems GEM_PATH=/opt/vanken-ruby/gems \
  /opt/vanken-ruby/bin/ruby /opt/vanken-ruby/gems/bin/vanken-setup-permissions \
  --ruby /opt/vanken-ruby/bin/ruby --gem-home /opt/vanken-ruby/gems --policy polkit
```

The installer checks the interpreter, its library paths, runtime tree, gem home, and source tree for root ownership and writable paths before copying anything. Root-owned runtime library aliases are allowed only when every link, target, and parent path passes the same checks. The wrapper clears all inherited environment variables, fixes the interpreter and gem paths, and runs only `/usr/local/libexec/vanken/helper`. The polkit policy authorizes that exact wrapper path. Launch Vanken as your ordinary user; polkit provides the administrator authentication dialog when capture requires elevation.

For headless Linux or sudo instead of polkit, create a dedicated capture group and add only users who should inspect network traffic. Log out and log in after changing group membership, then use `--policy sudoers --group vanken` in the setup command. The installer requires `visudo` and validates the rule before installing `/etc/sudoers.d/vanken`. It never grants capabilities to a shared Ruby interpreter.

## Install on macOS

On macOS, create the intended group, install the BPF daemon, and activate it:

```sh
sudo dseditgroup -o create vanken
sudo dseditgroup -o edit -a "$USER" -t user vanken
sudo "$(command -v vanken-setup-permissions)" --group vanken
sudo launchctl bootstrap system /Library/LaunchDaemons/org.vanken.chmod-bpf.plist
```

Log out and log in after joining the group. The daemon grants the group mode `0660` on existing BPF devices at startup and every ten seconds, including devices added later. It runs the fixed root-owned shell script; Vanken and the capture helper run as the normal user. Verify access with `vanken-capture --check --interface lo0`. If Wireshark's ChmodBPF already manages these devices, use that configuration instead of installing a second daemon.

Use `--root /absolute/staging-directory` to prepare files in an existing directory without activating system permissions. A staged tree is for review and packaging; it does not validate or grant trust to the runtime paths. Neither `--dry-run` nor staging loads the macOS daemon. To remove the installed macOS configuration, unload `org.vanken.chmod-bpf` with `launchctl bootout`, remove its plist and `chmod-bpf` script, and restore the BPF device ownership/permissions prescribed by your administrator.

## Capture helper security

The application runs as your normal user. The capture helper opens the capture device, drops supplementary groups and both real and effective group/user IDs, and writes pcapng to stdout. The interpreter, helper, libraries, gems, and every parent directory of the privileged wrapper must be owned by root and must not be writable by group or other users.

On macOS, grant the intended capture group access to `/dev/bpf*` using an administrator-managed startup configuration. Once `vanken-capture --check --interface lo0` reports `"direct":true`, Vanken can capture without sudo. Device permissions may need to be restored after a reboot.

## Manual Linux installation

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

## Verify device access

`vanken-capture --list-interfaces` lists interfaces without elevated privileges. `vanken-capture --check --interface IF` checks direct device access. A helper invoked manually with sudo needs `--drop-to` because the wrapper clears the environment:

```sh
sudo /usr/local/libexec/vanken/vanken-capture -i eth0 --drop-to "$(id -u):$(id -g)" > capture.pcapng
```

For the isolated Linux integration check, run `script/capture-ci.sh` with Docker available. It creates a disposable privileged container, runs `vanken-setup-permissions` against its root-owned Ruby/gems to install the fixed wrapper and sudoers policy, creates the `vanken-test` namespace and a veth pair, then runs the tests as an unprivileged user. The tests verify environment isolation, UID dropping, packet capture, statistics, and clean shutdown. The installer plan is saved as `permission-install.json`. The nightly `Live capture` workflow runs this same command.
