#!/usr/bin/env bash
# Control only the server belonging to this installation.
# Examples:
#   IP='::' PORT=9443 ./runserver.sh start
#   IP='127.0.0.1' PORT=9443 ./runserver.sh restart
#   IP='::' PORT=9443 ./runserver.sh foreground
# With no command, runs in foreground for a process supervisor.
# Omitted variables retain the saved listener. Changes persist in the config.
# TLS/authentication settings are preserved; failed validation restores the config.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export LSWS_HOME="$ROOT"
export OLS_PID_FILE="$ROOT/run/lshttpd.pid"
BINARY="$ROOT/bin/openlitespeed"
usage() {
    echo "Usage: [IP=ADDRESS] [PORT=NUMBER] $0 [start|stop|restart|reload|status|test|foreground|version]"
    echo 'No command defaults to foreground; use --help to show this help.'
    echo 'IP/PORT override only the HTTPS listener; omitted values retain the saved configuration.'
    echo 'Listener changes are saved after validation. Use restart to change a running listener.'
    echo 'foreground uses exec for supervision by a container or service manager.'
    cat <<'EOF'

Commands:
  start       Start in background; same-listener requests are idempotent.
  restart     Validate overrides/configuration before a full stop/start.
  reload      Graceful daemon restart via SIGUSR1; use restart for listener changes.
  foreground  Run with exec; stop any existing instance before invoking this.
  stop        Send SIGTERM; only this installation's main PID is targeted.
  status      Show the PID, or return exit status 3 when stopped.
  test        Validate and save explicit overrides, then check configuration.
  version     Print the server version.

IP must be an IPv4 or IPv6 address (bracketed IPv6 is also accepted).
PORT must be 1..65535. :: enables both IPv4 and IPv6 on this Linux build.
Specify either variable or both; unspecified values retain the saved value.
stop, status and version ignore IP/PORT. Passwords and TLS settings are untouched.

Examples:
  IP='::' PORT=9443 ./runserver.sh start
  PORT=9444 ./runserver.sh restart
  IP='::' PORT=9443 ./runserver.sh foreground

For foreground mode use the supervisor's restart operation.
Daemon signal behavior: SIGUSR1 gracefully restarts; SIGTERM stops;
SIGHUP requests delayed shutdown; SIGUSR2 is for worker debug logging.
EOF
}
case "${1:-foreground}" in help|--help|-h) usage; exit 0 ;; esac
mkdir -p "$ROOT/run" "$ROOT/logs"
exec 9>"$ROOT/run/control.lock"
flock -x 9
running() {
    PID=
    [[ -r "$OLS_PID_FILE" ]] || return 1
    read -r PID < "$OLS_PID_FILE" || return 1
    [[ "$PID" =~ ^[0-9]+$ ]] && ((PID > 1)) || return 1
    kill -0 "$PID" 2>/dev/null || return 1
    local exe owner
    exe=$(readlink "/proc/$PID/exe") || return 1
    owner=$(stat -c %u "/proc/$PID") || return 1
    [[ "$owner" == "$EUID" && ( "$exe" == "$BINARY" || "$exe" == "$BINARY (deleted)" ) ]]
}
test_config() { "$BINARY" -t; }
configure_listener() {
    if [[ -v IP || -v PORT ]]; then
        python3 "$ROOT/bin/configure-listener.py" "$ROOT" "$@"
    fi
}
start() {
    if running; then
        configure_listener --check
        echo "OpenLiteSpeed is running (PID $PID)."
        return
    fi
    if [[ ! -s "$ROOT/conf/auth/htpasswd" ]]; then
        echo "Create a site user first: $ROOT/siteuser.sh add USERNAME" >&2
        return 1
    fi
    configure_listener
    test_config
    python3 "$ROOT/bin/configure-listener.py" "$ROOT" --show
    (exec 9>&-; "$BINARY") >> "$ROOT/logs/launcher.log" 2>&1
    for ((attempt=0; attempt<100; attempt++)); do
        if running && python3 "$ROOT/bin/configure-listener.py" "$ROOT" --ready; then
            echo "OpenLiteSpeed started (PID $PID)."
            return
        fi
        sleep 0.1
    done
    echo "Startup failed; see $ROOT/logs/launcher.log and logs/error.log." >&2
    return 1
}
stop() {
    if ! running; then echo 'OpenLiteSpeed is stopped.'; return; fi
    local old_pid=$PID
    kill -TERM "$old_pid"
    for ((attempt=0; attempt<150; attempt++)); do
        if ! running; then echo 'OpenLiteSpeed stopped.'; return; fi
        sleep 0.1
    done
    echo "PID $old_pid has not stopped; inspect logs/error.log." >&2
    return 1
}
case "${1:-foreground}" in
    start) start ;;
    stop) stop ;;
    restart)
        # Validate overrides before stopping the current server.
        configure_listener
        test_config
        stop; start ;;
    reload)
        if ! running; then echo 'OpenLiteSpeed is stopped.' >&2; exit 3; fi
        configure_listener --check
        old_pid=$PID
        test_config
        running || { echo 'Server stopped during configuration check.' >&2; exit 1; }
        kill -USR1 "$PID"
        for ((attempt=0; attempt<150; attempt++)); do
            if running && [[ "$PID" != "$old_pid" ]]; then
                echo "OpenLiteSpeed reloaded (PID $PID)."
                exit 0
            fi
            sleep 0.1
        done
        echo 'Reload did not complete; inspect logs/error.log.' >&2
        exit 1 ;;
    status)
        if running; then echo "OpenLiteSpeed is running (PID $PID)."
        else echo 'OpenLiteSpeed is stopped.'; exit 3; fi ;;
    test) configure_listener; test_config ;;
    version) "$BINARY" -v ;;
    foreground)
        if running; then echo "Already running (PID $PID)." >&2; exit 1; fi
        [[ -s "$ROOT/conf/auth/htpasswd" ]] || { echo 'Create a site user first.' >&2; exit 1; }
        configure_listener
        test_config
        echo 'Starting OpenLiteSpeed in foreground (supervised).'
        python3 "$ROOT/bin/configure-listener.py" "$ROOT" --show
        exec 9>&-
        exec "$BINARY" -d ;;
    *) usage >&2; exit 2 ;;
esac
