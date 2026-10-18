#!/usr/bin/env bash
# Install an HTTPS static site with HTTP Basic Authentication as the current user.
#
# QUICK START
#   ./buildols.sh --strip
#   ./setupols.sh --docroot /path/to/static-site --user alice --start
#   For another Linux x86-64 host, copy dist/bin/openlitespeed-static from a
#   successful ./buildols.sh --strip build. Its filename alone does not prove
#   static linkage: readelf -l must show no INTERP, and -d no NEEDED entries.
#   A GLIBC_x.y not found error usually means a dynamically linked binary was
#   copied instead. Recopy the verified static output; do not replace system libc.
#
# DEFAULTS
#   Install: $HOME/apps/lsws; HTTPS: [::]:8443 (IPv4 and IPv6).
#   TLS: $HOME/.config/ssl/fullchain.pem and privkey.pem.
#   Runs as your current user without sudo. PHP/WebAdmin are disabled.
#   Static compression: Brotli preferred when accepted, gzip fallback; level 6.
#   Eligible compressible files: 300 bytes to 10 MiB. Already-compressed formats
#   are excluded by OpenLiteSpeed's default compressible MIME types.
#   Compressed variants are generated automatically in PREFIX/tmp/compression.
#   Clients that accept neither encoding receive the original uncompressed file.
#   Existing installs: stop the server, run ./setupols.sh --configure-compression,
#   then start it again. Other configuration, site content and accounts are retained.
#
# LISTENER CONFIGURATION
#   --bind/--port override IP/PORT environment variables.
#   For new installs, omitted values default to :: and 8443.
#   Existing installs preserve saved settings unless explicitly overridden.
#   IP='::' PORT=9443 ./setupols.sh --docroot /path/to/site --user alice
#
# AFTER INSTALLATION
#   ~/apps/lsws/siteuser.sh add alice     # Add a user or change their password.
#   ~/apps/lsws/siteuser.sh list
#   ~/apps/lsws/siteuser.sh delete alice
#   ~/apps/lsws/runserver.sh reload       # Apply account/config changes.
#   IP='::' PORT=9443 ~/apps/lsws/runserver.sh restart
#   IP='::' PORT=9443 ~/apps/lsws/runserver.sh foreground
#
# runserver.sh validates and saves explicit IP/PORT changes to the HTTPS
# listener only; TLS, document root and authentication remain intact. Omitted
# values retain the saved listener. Invalid overrides leave it unchanged.
# start refuses different overrides when already running; use restart instead.
# foreground uses exec (no shell wrapper), for a container/service supervisor.
# No command defaults to foreground: a supervisor can launch runserver.sh
# directly with IP/PORT in its environment. Use --help for usage information.
# The effective HTTPS listener is printed to stdout before starting the server.
# In foreground mode, use the supervisor to restart the process.
# Daemon-mode reload sends SIGUSR1 for a graceful restart; stop sends SIGTERM.
# SIGHUP requests shutdown, not reload. SIGUSR2 toggles worker debug logging.
#
# UPGRADES
#   Stop the installed server, then rerun this script. Configuration, accounts
#   and site content are preserved. --clean first moves the entire installation
#   to PREFIX.backup-TIMESTAMP-PID; an external document root is never removed.
#   See ./setupols.sh --help for all options and noninteractive password input.
set -euo pipefail
umask 077
SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PREFIX="${HOME}/apps/lsws"
DOCROOT=
CERT_DIR="${HOME}"
CERT=
KEY=
BIND=${IP-::}
PORT=${PORT-8443}
BIND_EXPLICIT=${IP+x}
PORT_EXPLICIT=${PORT+x}
VARIANT=static
CLEAN=0
CONFIGURE_COMPRESSION=0
START=0
USERNAME=
PASSWORD_STDIN=0
usage() {
    cat <<'EOF'
Usage: ./setupols.sh [options]
  --prefix DIR         Installation directory (default: $HOME/apps/lsws)
  --docroot DIR        Existing static site directory (default: PREFIX/html)
  --cert-dir DIR       Certificate directory (default: $HOME/.config/ssl)
                       Uses fullchain.pem and privkey.pem.
  --tls-cert FILE      Override the certificate/full chain file
  --tls-key FILE       Override the unencrypted private key file
  --bind ADDRESS       Listener IP (default: :: for IPv4 + IPv6)
                       Use 0.0.0.0 for IPv4 only, or 127.0.0.1 for local IPv4.
  --port PORT          HTTPS port (default: 8443)
  --variant NAME       static or dynamic (default: static)
  --user USERNAME      Create/update a site Basic Auth account
  --password-stdin     Read that account's password from stdin instead of prompting
  --start              Start after installation (requires a site account)
  --clean              Back up the target directory before a fresh installation
  --configure-compression
                       Enable Brotli + gzip on an existing install without cleaning
  --help               Show help

Existing site configuration/content/passwords are preserved unless --clean is used.
IP and PORT environment variables set the listener; --bind/--port take precedence.
Explicit listener overrides also update existing installs, preserving other settings.
The installed runserver.sh accepts IP/PORT for start, restart, test and foreground.
With no command it defaults to foreground, for launchers that supply only IP/PORT.
The effective HTTPS listener is printed to stdout on start/foreground.
Omitted runtime values retain the saved listener. Explicit overrides are validated
and saved in conf/httpd_config.conf, so subsequent runs without overrides reuse them.
Invalid overrides leave the saved listener unchanged. stop/status/version ignore them.
Stop a running installation before upgrading or cleaning it. No sudo is needed.

Example: ./setupols.sh --docroot "$HOME/www/site" --user alice --start
Example: IP='::' PORT=9443 ./setupols.sh --docroot "$HOME/www/site" --user alice
Example: IP='::' PORT=9443 ~/apps/lsws/runserver.sh foreground
Example: IP='::' PORT=9443 ~/apps/lsws/runserver.sh restart

Runtime control:
  start       Start in the background; if running, different overrides are refused.
  foreground  Run with exec for a process supervisor; stop any existing instance first.
  restart     Validate configuration, then fully stop/start to apply listener changes.
  reload      Graceful daemon restart via SIGUSR1; different IP/PORT require restart.
  stop        Stop with SIGTERM.
  status      Show the main PID; exit status 3 means stopped.
  test        Apply/validate explicit listener overrides and check configuration.
  version     Print the server version.
Use a supervisor restart in foreground mode. SIGHUP shuts down; it does not reload.

Static compression (enabled by default for new installs):
  Prefer Brotli (br) when accepted by the client; gzip is available as a fallback.
  Brotli/gzip use level 6. Eligible MIME types follow OpenLiteSpeed's defaults;
  files must be 300 bytes to 10 MiB. Encoded files are cached in PREFIX/tmp/compression.
  Clients accepting neither encoding receive the original file. Large files may
  initially be served uncompressed while the cache is generated in the background.
  To enable these defaults on an existing install, stop it and run:
    ./setupols.sh --configure-compression --start
  This changes only compression settings; existing site/TLS/auth settings remain.

Site accounts (HTTP Basic Auth, not Unix or WebAdmin accounts):
  ~/apps/lsws/siteuser.sh add alice       # Hidden password and confirmation prompts.
  ~/apps/lsws/siteuser.sh list
  ~/apps/lsws/siteuser.sh delete alice
  ~/apps/lsws/runserver.sh reload        # Clear cached credentials immediately.
For automation, feed a password on stdin with --user NAME --password-stdin;
avoid putting passwords in command-line arguments. Passwords are stored as hashes
in conf/auth/htpasswd, outside the document root, with permissions 0600.
EOF
}
die() { echo "ERROR: $*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --prefix|--docroot|--cert-dir|--tls-cert|--tls-key|--bind|--port|--variant|--user)
            [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
            option=$1; value=$2; shift 2
            case "$option" in
                --prefix) PREFIX=$value ;; --docroot) DOCROOT=$value ;;
                --cert-dir) CERT_DIR=$value ;; --tls-cert) CERT=$value ;;
                --tls-key) KEY=$value ;; --bind) BIND=$value; BIND_EXPLICIT=x ;;
                --port) PORT=$value; PORT_EXPLICIT=x ;;
                --variant) VARIANT=$value ;; --user) USERNAME=$value ;;
            esac ;;
        --clean) CLEAN=1; shift ;; --start) START=1; shift ;;
        --configure-compression) CONFIGURE_COMPRESSION=1; shift ;;
        --password-stdin) PASSWORD_STDIN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
[[ "$VARIANT" == static || "$VARIANT" == dynamic ]] || die 'Variant must be static or dynamic'
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT >= 1 && 10#$PORT <= 65535)) || die 'Invalid port'
((!PASSWORD_STDIN)) || [[ -n "$USERNAME" ]] || die '--password-stdin requires --user'
[[ -z "$USERNAME" || "$USERNAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || die 'Invalid username'
((EUID > 10)) && (($(id -g) >= 10)) || die 'Run this per-user installer without sudo as a regular user'
for tool in python3 openssl flock install readlink stat awk; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
PREFIX=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$PREFIX")
python3 - "$PREFIX" "$SOURCE" <<'PY'
from pathlib import Path
import sys
target, source = map(Path, sys.argv[1:])
home = Path.home().resolve()
if target in (home, source, Path('/')) or target in source.parents or target in home.parents:
    raise SystemExit('Refusing an installation path that contains the home or source directory.')
PY
[[ ! -e "$PREFIX" || -d "$PREFIX" ]] || die 'Install path is not a directory'
if [[ -r "$PREFIX/run/lshttpd.pid" ]]; then
    read -r pid < "$PREFIX/run/lshttpd.pid" || true
    if [[ "${pid:-}" =~ ^[0-9]+$ ]] && ((pid > 1)) && kill -0 "$pid" 2>/dev/null; then
        die "Target has a live PID $pid; stop it before installing"
    fi
fi
FRESH=1
[[ ! -f "$PREFIX/conf/httpd_config.conf" || "$CLEAN" == 1 ]] || FRESH=0
BINARY="$SOURCE/dist/bin/openlitespeed-$VARIANT"
[[ -x "$BINARY" ]] || die "Build the binary first: $SOURCE/buildols.sh --strip"
if [[ "$VARIANT" == static ]]; then
    command -v readelf >/dev/null || die 'Missing tool: readelf (install binutils to verify static linkage)'
    elf_headers=$(LC_ALL=C readelf --wide --program-headers "$BINARY") || die "Cannot inspect ELF binary: $BINARY"
    elf_dynamic=$(LC_ALL=C readelf --wide --dynamic "$BINARY") || die "Cannot inspect ELF dependencies: $BINARY"
    if [[ "$elf_headers" == *INTERP* || "$elf_dynamic" == *NEEDED* ]]; then
        die "$BINARY is dynamically linked despite its static filename. Rebuild with ./buildols.sh --strip or copy the verified dist/bin/openlitespeed-static from the build machine."
    fi
fi
"$BINARY" -v >/dev/null || die "Binary cannot run on this host: $BINARY (check CPU architecture and, for --variant dynamic, the host glibc version)"
if ((FRESH)); then
    [[ -n "$DOCROOT" ]] || DOCROOT="$PREFIX/html"
    DOCROOT=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$DOCROOT")
    python3 - "$PREFIX" "$DOCROOT" "$BIND" <<'PY'
from pathlib import Path
import ipaddress
import sys
root, docroot = map(Path, sys.argv[1:3])
ipaddress.ip_address(sys.argv[3].strip('[]'))
if root == docroot or docroot in root.parents or docroot.is_relative_to(root / 'conf') or docroot.is_relative_to(root / 'run'):
    raise SystemExit('Document root must not expose installation configuration or runtime files.')
if root in docroot.parents and docroot != root / 'html':
    raise SystemExit('Use PREFIX/html or a document root outside the installation.')
if docroot != root / 'html' and not docroot.is_dir():
    raise SystemExit('The external document root must already exist.')
PY
    CERT=${CERT:-"$CERT_DIR/fullchain.pem"}
    KEY=${KEY:-"$CERT_DIR/privkey.pem"}
    # Keep certificate symlinks intact so renewal can replace their targets.
    CERT=$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$CERT")
    KEY=$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$KEY")
    [[ -r "$CERT" && -r "$KEY" ]] || die 'Certificate/key unreadable; use --cert-dir or --tls-cert/--tls-key'
    cert_public=$(openssl x509 -in "$CERT" -pubkey -noout)
    key_public=$(openssl pkey -in "$KEY" -pubout -passin pass:)
    [[ "$cert_public" == "$key_public" ]] || die 'Certificate and private key do not match'
    openssl x509 -in "$CERT" -checkend 0 -noout >/dev/null || die 'Certificate has expired'
    # Absolute certificate paths keep automatic certificate renewal working.
    if ((CLEAN)) && [[ -d "$PREFIX" ]]; then
        [[ "$CERT" != "$PREFIX/"* && "$KEY" != "$PREFIX/"* ]] || die 'Clean install needs certificates outside the target directory'
        backup="$PREFIX.backup-$(date +%Y%m%d-%H%M%S)-$$"
        mv -- "$PREFIX" "$backup"
        echo "Previous installation backed up to: $backup"
    fi
fi
mkdir -p "$PREFIX"/{bin,conf/auth,conf/vhosts/site,logs,run/status,tmp/swap,tmp/compression,cachedata,autoupdate,cgid,admin/tmp,share/autoindex}
chmod 700 "$PREFIX/conf/auth" "$PREFIX/run"
install -m 755 "$BINARY" "$PREFIX/bin/openlitespeed"
ln -sfn openlitespeed "$PREFIX/bin/litespeed"
ln -sfn openlitespeed "$PREFIX/bin/lshttpd"
install -m 755 "$SOURCE/scripts/ols/runserver.sh" "$PREFIX/runserver.sh"
install -m 755 "$SOURCE/scripts/ols/siteuser.sh" "$PREFIX/siteuser.sh"
install -m 755 "$SOURCE/scripts/ols/configure-listener.py" "$PREFIX/bin/configure-listener.py"
if ((FRESH)); then
    install -m 644 "$SOURCE/dist/conf/mime.properties" "$PREFIX/conf/mime.properties"
    python3 "$SOURCE/scripts/ols/render-config.py" "$PREFIX" "$DOCROOT" "$BIND" "$PORT" "$CERT" "$KEY"
    if [[ "$DOCROOT" == "$PREFIX/html" ]]; then
        mkdir -p "$DOCROOT"
        if [[ ! -e "$DOCROOT/index.html" ]]; then
            printf '%s\n' '<!doctype html><title>Private website</title><h1>OpenLiteSpeed is running.</h1>' > "$DOCROOT/index.html"
        fi
    fi
    [[ -e "$PREFIX/conf/auth/htpasswd" ]] || : > "$PREFIX/conf/auth/htpasswd"
    chmod 600 "$PREFIX/conf/auth/htpasswd"
    display_bind=$BIND
    if [[ "$display_bind" == *:* && "$display_bind" != \[* ]]; then
        display_bind="[$display_bind]"
    fi
    echo "Website: https://$display_bind:$PORT/"
    echo "Document root: $DOCROOT"
else
    echo 'Existing configuration, document root and accounts preserved.'
    if ((CONFIGURE_COMPRESSION)); then
        python3 "$SOURCE/scripts/ols/render-config.py" --compression "$PREFIX"
    fi
fi
if [[ -n "$USERNAME" ]]; then
    password_options=()
    (( !PASSWORD_STDIN )) || password_options+=(--password-stdin)
    "$PREFIX/siteuser.sh" add "$USERNAME" "${password_options[@]}"
fi
listener_options=()
[[ -z "$BIND_EXPLICIT" ]] || listener_options+=("IP=$BIND")
[[ -z "$PORT_EXPLICIT" ]] || listener_options+=("PORT=$PORT")
env "${listener_options[@]}" "$PREFIX/runserver.sh" test
echo "Installed $VARIANT OpenLiteSpeed in $PREFIX"
echo "Manage accounts: $PREFIX/siteuser.sh add USERNAME"
echo "Control server: $PREFIX/runserver.sh {start|stop|restart|reload|status}"
if ((START)); then env "${listener_options[@]}" "$PREFIX/runserver.sh" start; fi
