# Flox curl-pipe installer

A single POSIX `sh` script (`install.sh`) that installs Flox with one command,
in the style of `curl https://mise.run | sh`:

```sh
curl -fsSL https://flox.dev/install.sh | sh
```

Flox already ships native packages (`.pkg`, `.deb`, `.rpm`) and documents how to
install each one by hand. This script is the missing "just run this" front door:
it detects your platform, downloads the right package from
`downloads.flox.dev`, and installs it with the system package manager.

## What it does

1. **Nix precondition.** If Nix is already installed (`nix` on `PATH`, or `/nix`
   or `/etc/nix/nix.conf` present), it stops and points the user at the
   Nix-aware instructions at <https://flox.dev/docs/install-flox/install>.
   Installing Flox reconfigures an existing Nix, so we refuse rather than
   silently clobber it.
2. **Detects CPU architecture** via `uname -m` (`x86_64`/`amd64` →  `x86_64`,
   `aarch64`/`arm64` → `aarch64`).
3. **Detects OS / package family:**
   - macOS (`Darwin`) → `.pkg`, installed with `installer -pkg … -target /`
     (the non-interactive equivalent of the double-click flow used by the
     `jbayer/flox-upgrade` environment).
   - Linux → prefers the package manager that is actually present
     (`apt-get`/`dpkg` → `.deb`, `dnf`/`yum`/`rpm` → `.rpm`), falling back to
     `/etc/os-release` `ID`/`ID_LIKE` detection.
4. **Resolves the version** dynamically from
   `https://downloads.flox.dev/by-env/stable/LATEST_VERSION` so the hosted
   script never needs editing on each release.
5. **Downloads and installs** with the right tool. For `.rpm` it first imports
   the Flox signing key (`flox-archive-keyring.asc`).

### Design choices already made

- **POSIX `sh`**, not bash — runs under `sh`/`dash` for pipe-to-shell safety.
- Works with **either `curl` or `wget`** as the fetcher.
- Downloads to a `mktemp` dir cleaned up via an exit trap.
- `sudo` is only invoked at install time, and skipped when already root.
- `curl` uses `--proto '=https' --tlsv1.2`.
- Overridable via environment variables:
  - `FLOX_CHANNEL` (default `stable`)
  - `FLOX_VERSION` (default: whatever the channel's `LATEST_VERSION` reports)

### Platforms covered

| OS                         | Arch              | Package | Installer                         |
| -------------------------- | ----------------- | ------- | --------------------------------- |
| macOS                      | aarch64 / x86_64  | `.pkg`  | `installer -pkg … -target /`      |
| Debian / Ubuntu            | x86_64 / aarch64  | `.deb`  | `apt-get install` (dpkg fallback) |
| Fedora / RHEL / CentOS     | x86_64 / aarch64  | `.rpm`  | `dnf` / `yum` / `rpm`             |

All six package URLs plus the keyring were confirmed to return `200` against
`downloads.flox.dev` at the time of writing (Flox 1.13.0).

## What remains to be done

- [ ] **Smoke tests / CI.** Run the script end-to-end in throwaway containers
      for each target: Ubuntu, Debian, Fedora, an RPM-based distro, and macOS
      (Apple Silicon + Intel). Assert that `flox --version` works afterward.
      Include a "Nix already installed" case asserting the precondition exits
      non-zero with the docs link.
- [ ] **`shellcheck` in CI.** Not yet run here (shellcheck isn't installed in
      this environment); wire it into the test workflow.
- [ ] **Checksum / signature verification.** Verify the downloaded package
      against a published checksum (and/or GPG signature) before installing,
      rather than trusting TLS alone. Needs a decision on what Flox publishes
      alongside the packages.
- [ ] **Hosting + redirects.** Decide the canonical URL (see open decisions),
      publish the file, and set up any short-domain redirect.
- [ ] **`unstable` channel coverage.** Confirm `FLOX_CHANNEL=unstable` resolves
      and installs correctly, or document it as unsupported.
- [ ] **Older/edge package managers.** The `dpkg` + `apt-get -f install`
      fallback path and the bare `rpm -Uvh` path are written but untested on
      real legacy systems.
- [ ] **Distro coverage gaps.** Decide how to handle distros that aren't clearly
      Debian- or RHEL-like (e.g. Arch, Alpine/musl, openSUSE/zypper). Currently
      they hit a clear error pointing at the docs.
- [ ] **PATH messaging.** Confirm the post-install "open a new terminal" hint
      matches what each package actually does to the user's shell profile.

## Open decisions

1. **Canonical install URL.**
   - `https://flox.dev/install.sh` — keeps everything on the existing domain,
     no new DNS/cert, obvious provenance.
   - `https://flox.run | sh` — shorter, mirrors `mise.run`, nicer to type and
     to put on a slide. Requires a new domain + TLS + a redirect/proxy to the
     same file.
   - These aren't exclusive: we can host the file at `flox.dev/install.sh` and
     point a short domain at it. **Decision needed:** do we register a short
     domain now, and which one?

2. **Release channel default.** Script defaults to `stable`. Confirm that's the
   right default for an unqualified `curl … | sh`, and how (if at all) we expose
   `unstable`.

3. **Signature/checksum policy.** Whether to require verification before install
   (see remaining work) — depends on what artifacts Flox publishes next to the
   packages.

4. **Homebrew on macOS.** The script uses the `.pkg` directly. Decide whether to
   prefer/offer `brew install flox` when Homebrew is detected, or keep `.pkg` as
   the single, predictable macOS path.

5. **Telemetry / metrics.** Whether the hosted endpoint should record install
   counts (e.g. via server-side request logging) and whether that needs to be
   disclosed in the script output.

## Trying it locally

```sh
sh -n install.sh        # syntax check
sh install.sh           # run (will refuse if Nix is present)
FLOX_VERSION=1.13.0 sh install.sh
```
