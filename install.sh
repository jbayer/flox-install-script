#!/bin/sh
#
# Flox installer — curl-pipe-to-shell bootstrap.
#
#   curl -fsSL https://flox.dev/install.sh | sh
#
# Detects your OS and CPU architecture, downloads the matching native Flox
# package from downloads.flox.dev, and installs it with the system package
# manager:
#
#   * macOS                 -> .pkg installed with `installer`
#   * Debian / Ubuntu       -> .deb installed with `apt`
#   * Fedora / RHEL / etc.  -> .rpm installed with `rpm`
#
# Precondition: if Flox is already installed we stop and point you at the
# system package manager for upgrades, and likewise bail out if Nix is already
# installed, because installing Flox reconfigures an existing Nix.
#
# Override the release channel or version:
#   FLOX_CHANNEL=stable   (default)
#   FLOX_VERSION=1.13.0   (default: whatever the channel currently publishes)

set -eu

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
FLOX_CHANNEL="${FLOX_CHANNEL:-stable}"
BASE_URL="https://downloads.flox.dev/by-env/${FLOX_CHANNEL}"
DOCS_URL="https://flox.dev/docs/install-flox/install"

# --------------------------------------------------------------------------
# Pretty output
# --------------------------------------------------------------------------
if [ -t 2 ]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"; YELLOW="$(printf '\033[33m')"
  RESET="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info()  { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn()  { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# A privilege-escalation prefix. Empty when we are already root.
SUDO=""
need_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    have sudo || die "this installer needs root privileges but 'sudo' was not found; re-run as root"
    SUDO="sudo"
  fi
}

# Download $1 to $2 using whatever fetcher is available.
download() {
  url="$1"; dest="$2"
  if have curl; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url"
  elif have wget; then
    wget -qO "$dest" "$url"
  else
    die "neither 'curl' nor 'wget' is available to download $url"
  fi
}

# Read a small remote file to stdout.
fetch() {
  url="$1"
  if have curl; then
    curl -fsSL --proto '=https' --tlsv1.2 "$url"
  elif have wget; then
    wget -qO- "$url"
  else
    die "neither 'curl' nor 'wget' is available to fetch $url"
  fi
}

# --------------------------------------------------------------------------
# Precondition: bail out if Flox is already installed
# --------------------------------------------------------------------------
flox_present() {
  have flox && return 0
  [ -e /usr/bin/flox ] && return 0
  [ -e /usr/local/bin/flox ] && return 0
  return 1
}

# Suggest the package-manager command appropriate for this system to manage an
# existing Flox installation.
flox_upgrade_hint() {
  if [ "$(uname -s)" = "Darwin" ]; then
    if have brew && brew list --cask flox >/dev/null 2>&1; then
      printf 'brew upgrade --cask flox'
    else
      printf 'sudo installer (re-run the .pkg from https://flox.dev/docs/install-flox/install)'
    fi
  elif have apt-get || have dpkg; then
    printf 'sudo apt-get update && sudo apt-get install --only-upgrade flox'
  elif have dnf; then
    printf 'sudo dnf upgrade flox'
  elif have yum; then
    printf 'sudo yum update flox'
  elif have rpm; then
    printf 'sudo rpm -Uvh <new flox .rpm>'
  else
    printf 'see %s for upgrade instructions' "$DOCS_URL"
  fi
}

if flox_present; then
  cat >&2 <<EOF
${BOLD}Flox is already installed on this system.${RESET}

$(have flox && flox --version 2>/dev/null)

To upgrade or manage it, use your system package manager, for example:

    ${BOLD}$(flox_upgrade_hint)${RESET}

EOF
  exit 0
fi

# --------------------------------------------------------------------------
# Precondition: bail out if Nix is already installed
# --------------------------------------------------------------------------
nix_present() {
  have nix && return 0
  [ -e /nix ] && return 0
  [ -e /etc/nix/nix.conf ] && return 0
  return 1
}

if nix_present; then
  cat >&2 <<EOF
${BOLD}Nix is already installed on this system.${RESET}

Installing Flox the normal way reconfigures an existing Nix installation,
which is probably not what you want. Please follow the Nix-aware instructions:

    ${BOLD}${DOCS_URL}${RESET}

EOF
  exit 1
fi

# --------------------------------------------------------------------------
# Detect architecture
# --------------------------------------------------------------------------
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64)          ARCH="x86_64" ;;
  aarch64 | arm64)         ARCH="aarch64" ;;
  *) die "unsupported CPU architecture: ${arch} (Flox ships x86_64 and aarch64 builds)" ;;
esac

# --------------------------------------------------------------------------
# Detect OS and pick a package family
# --------------------------------------------------------------------------
os="$(uname -s)"
case "$os" in
  Darwin) PKG_KIND="pkg" ;;
  Linux)
    # Prefer the package manager that is actually present; fall back to
    # os-release family detection.
    if have apt-get || have dpkg; then
      PKG_KIND="deb"
    elif have dnf || have yum || have rpm; then
      PKG_KIND="rpm"
    elif [ -r /etc/os-release ]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "* | *" ubuntu "*)               PKG_KIND="deb" ;;
        *" rhel "* | *" fedora "* | *" centos "*)  PKG_KIND="rpm" ;;
        *) die "could not determine a supported package manager for this Linux distribution (ID=${ID:-unknown}); see ${DOCS_URL}" ;;
      esac
    else
      die "could not find apt/dpkg or dnf/yum/rpm, and /etc/os-release is unreadable; see ${DOCS_URL}"
    fi
    ;;
  *) die "unsupported operating system: ${os}" ;;
esac

# --------------------------------------------------------------------------
# Resolve the version to install
# --------------------------------------------------------------------------
if [ -n "${FLOX_VERSION:-}" ]; then
  VERSION="$FLOX_VERSION"
else
  info "Resolving the latest Flox version (${FLOX_CHANNEL} channel)..."
  VERSION="$(fetch "${BASE_URL}/LATEST_VERSION" | tr -d '[:space:]')"
  [ -n "$VERSION" ] || die "could not determine the latest Flox version from ${BASE_URL}/LATEST_VERSION"
fi

# --------------------------------------------------------------------------
# Build the download URL for the chosen platform
# --------------------------------------------------------------------------
case "$PKG_KIND" in
  pkg) PLATFORM="${ARCH}-darwin"; URL="${BASE_URL}/osx/flox-${VERSION}.${PLATFORM}.pkg" ;;
  deb) PLATFORM="${ARCH}-linux";  URL="${BASE_URL}/deb/flox-${VERSION}.${PLATFORM}.deb" ;;
  rpm) PLATFORM="${ARCH}-linux";  URL="${BASE_URL}/rpm/flox-${VERSION}.${PLATFORM}.rpm" ;;
esac

# --------------------------------------------------------------------------
# Download to a temp dir we clean up on exit
# --------------------------------------------------------------------------
TMPDIR_INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/flox-install.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_INSTALL"; }
trap cleanup EXIT INT TERM

PKG_FILE="${TMPDIR_INSTALL}/flox-${VERSION}.${PLATFORM}.${PKG_KIND}"

info "Installing Flox ${BOLD}${VERSION}${RESET} for ${BOLD}${PLATFORM}${RESET}"
info "Downloading ${URL}"
download "$URL" "$PKG_FILE" || die "download failed: ${URL}"

# --------------------------------------------------------------------------
# Install with the platform's package manager
# --------------------------------------------------------------------------
case "$PKG_KIND" in
  pkg)
    need_sudo
    info "Running the macOS package installer (you may be prompted for your password)"
    $SUDO installer -pkg "$PKG_FILE" -target / \
      || die "the macOS installer failed"
    ;;
  deb)
    need_sudo
    info "Installing the .deb package with apt"
    if have apt-get; then
      $SUDO apt-get install -y "$PKG_FILE" \
        || die "apt-get install failed"
    else
      # Older systems without `apt`/`apt-get` resolving local files.
      $SUDO dpkg -i "$PKG_FILE" || { $SUDO apt-get -f install -y && $SUDO dpkg -i "$PKG_FILE"; } \
        || die "dpkg install failed"
    fi
    ;;
  rpm)
    need_sudo
    info "Importing the Flox package-signing key"
    $SUDO rpm --import "${BASE_URL}/rpm/flox-archive-keyring.asc" \
      || warn "could not import the Flox signing key; continuing"
    info "Installing the .rpm package"
    if have dnf; then
      $SUDO dnf install -y "$PKG_FILE" || die "dnf install failed"
    elif have yum; then
      $SUDO yum install -y "$PKG_FILE" || die "yum install failed"
    else
      $SUDO rpm -Uvh "$PKG_FILE" || die "rpm install failed"
    fi
    ;;
esac

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
printf '\n'
if have flox; then
  info "${GREEN}Flox installed:${RESET} $(flox --version 2>/dev/null || echo "$VERSION")"
else
  info "${GREEN}Flox ${VERSION} installed.${RESET}"
  warn "Open a new terminal (or re-source your shell profile) so 'flox' is on your PATH."
fi
printf '\nGet started:  %sflox --help%s   |   Docs: %shttps://flox.dev/docs%s\n' \
  "$BOLD" "$RESET" "$BOLD" "$RESET" >&2
