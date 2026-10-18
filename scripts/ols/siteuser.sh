#!/usr/bin/env bash
# Manage HTTP Basic Authentication accounts, not Unix or WebAdmin accounts.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PASSFILE="$ROOT/conf/auth/htpasswd"
usage() {
    echo "Usage: $0 {add|delete} USERNAME [--password-stdin]"
    echo "       $0 list"
    echo 'add also changes an existing password; prompts hide password input.'
}
action=${1:-help}
case "$action" in help|--help|-h) usage; exit 0 ;; esac
[[ -d "$ROOT/conf/auth" ]] || { echo 'Installation is missing conf/auth.' >&2; exit 1; }
[[ ! -L "$PASSFILE" ]] || { echo 'Refusing a symlinked password file.' >&2; exit 1; }
exec 9>"$ROOT/conf/auth/.lock"
flock -x 9
if [[ "$action" == list && $# == 1 ]]; then
    [[ ! -f "$PASSFILE" ]] || cut -d: -f1 "$PASSFILE"
    exit 0
fi
[[ "$action" == add || "$action" == delete ]] || { usage >&2; exit 2; }
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
username=$2
[[ "$username" =~ ^[A-Za-z0-9_.@-]+$ ]] || { echo 'Invalid username.' >&2; exit 2; }
stdin_password=0
if [[ $# == 3 ]]; then
    [[ "$action" == add && "$3" == --password-stdin ]] || { usage >&2; exit 2; }
    stdin_password=1
fi
hash=
if [[ "$action" == add ]]; then
    if ((stdin_password)); then
        IFS= read -r password || [[ -n "${password:-}" ]]
    else
        [[ -t 0 ]] || { echo 'Use --password-stdin for noninteractive input.' >&2; exit 2; }
        IFS= read -rs -p 'Password: ' password; echo
        IFS= read -rs -p 'Confirm password: ' confirmation; echo
        [[ "$password" == "$confirmation" ]] || { echo 'Passwords do not match.' >&2; exit 1; }
        unset confirmation
    fi
    [[ ${#password} -ge 8 ]] || { echo 'Use at least 8 characters.' >&2; exit 2; }
    hash=$(printf '%s\n' "$password" | openssl passwd -6 -stdin)
    unset password
    [[ "$hash" == '$6$'* ]] || { echo 'Password hashing failed.' >&2; exit 1; }
fi
temporary=$(mktemp "$ROOT/conf/auth/.htpasswd.XXXXXX")
trap '[[ ! -f "$temporary" ]] || unlink "$temporary"' EXIT
if [[ -f "$PASSFILE" ]]; then
    awk -F: -v user="$username" '$1 != user' "$PASSFILE" > "$temporary"
fi
if [[ "$action" == add ]]; then printf '%s:%s\n' "$username" "$hash" >> "$temporary"; fi
chmod 600 "$temporary"
mv -f -- "$temporary" "$PASSFILE"
echo "Site user $username: $action completed."
echo "Apply immediately with: $ROOT/runserver.sh reload"
