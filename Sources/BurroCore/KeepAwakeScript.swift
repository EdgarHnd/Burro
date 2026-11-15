// The shell programs behind Keep Awake. They are passed to /bin/sh as text (never written to a file),
// so nothing on disk can be swapped between an administrator prompt and the command it approves.
import Foundation

public enum KeepAwakeScript {
    /// `$0` of every Keep Awake shell. Mac Health recognises the watchdog by it and never lists it as a leftover.
    public static let processName = "burro-keep-awake"
    /// The sudoers file Burro installs and removes; nothing else in /etc/sudoers.d is touched.
    public static let rulePath = "/etc/sudoers.d/burro-keep-awake"

    /// One session of `pmset -a disablesleep 1`, always undone. Modelled on NoSleepBar (EdgarHnd/nosleep):
    /// the same pmset flag, passwordless sudo first and the administrator prompt otherwise, plus a watchdog
    /// so sleep comes back on even when Burro is closed, rebuilt, killed or stops answering.
    public static let session = #"""
# Burro Keep Awake: one session of `pmset -a disablesleep 1` that is always undone.
# Runs as root (after an administrator prompt) or as the user when sudoers allows exactly
# `/usr/bin/pmset -a disablesleep 0` and `... 1` without a password.
#
#   start OWNER MARKER
#
# Turns lid-closed sleep off and leaves a watchdog that turns it back on when MARKER is removed
# (Stop), MARKER goes 15 minutes without being touched (Burro stopped answering), or OWNER exits
# and no new Burro takes the session over within GRACE seconds by writing its pid to the file
# "adopt" beside MARKER. Prints "WATCHER LOCK".
# Exit 3: passwordless pmset is not allowed. Exit 4: another session is running or restoring.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
PMSET=/usr/bin/pmset
SUDO=/usr/bin/sudo
TICK=2
GRACE=30
if [ "$(id -u)" = 0 ]; then
    lock=/var/run/local.burro.keepawake
    allowed() { true; }
    set_sleep() { "$PMSET" -a disablesleep "$1"; }
else
    lock=${TMPDIR:-/tmp}
    lock="${lock%/}/local.burro.keepawake"
    # -k ignores a recently typed sudo password, so only a real NOPASSWD rule counts.
    allowed() { "$SUDO" -n -k -l "$PMSET" -a disablesleep 1 && "$SUDO" -n -k -l "$PMSET" -a disablesleep 0; } >/dev/null 2>&1
    set_sleep() { "$SUDO" -n "$PMSET" -a disablesleep "$1"; }
fi
digits() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

restore() {
    trap '' HUP INT TERM
    # Keep trying rather than leave a global sleep override behind; back off after a minute.
    tries=0
    until set_sleep 0 >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -lt 30 ]; then sleep 2; else sleep 30; fi
    done
    rm -f "$lock/ready" "$lock/armed" "$lock/owner" "$lock/owner.tmp" "$lock/watcher"
    rmdir "$lock" 2>/dev/null
}

# A new Burro asks to take over by writing its pid to "adopt" beside the marker. Only a live process
# with the same program name is accepted; the answer goes to "$lock/owner", never into Burro's folder.
try_adopt() {
    [ -f "$adopt" ] && [ ! -L "$adopt" ] || return 1
    next=$(head -c 16 "$adopt" 2>/dev/null | tr -cd 0-9)
    digits "$next" && [ "$next" -gt 1 ] && [ "$next" != "$owner" ] || return 1
    kill -0 "$next" 2>/dev/null || return 1
    name=$(ps -p "$next" -o comm= 2>/dev/null) || return 1
    [ "${name##*/}" = "$program" ] || return 1
    started=$(ps -p "$next" -o lstart= 2>/dev/null)
    [ -n "$started" ] || return 1
    owner=$next
    identity=$started
    printf '%s\n' "$owner" > "$lock/owner.tmp" && mv -f "$lock/owner.tmp" "$lock/owner"
}

owner_gone() {
    limit=$(( $(date +%s) + GRACE ))
    while [ -f "$marker" ] && [ "$(date +%s)" -lt "$limit" ]; do
        try_adopt && return 0
        sleep 1
    done
    return 1
}

watch() {
    owner=$1; identity=$2; program=$3; marker=$4
    adopt="${marker%/*}/adopt"
    trap '' HUP
    trap restore EXIT
    trap 'exit 0' INT TERM
    touch "$lock/armed"
    waited=0
    while [ ! -f "$lock/ready" ]; do
        [ "$waited" -lt 300 ] || exit 0
        waited=$((waited + 1)); sleep 0.1
    done
    tick=0
    while [ -f "$marker" ]; do
        if [ $((tick % 5)) = 0 ]; then
            [ -z "$(find "$marker" -mmin +15 2>/dev/null)" ] || exit 0
            [ "$(ps -p "$owner" -o lstart= 2>/dev/null)" = "$identity" ] || owner_gone || exit 0
        elif ! kill -0 "$owner" 2>/dev/null; then
            owner_gone || exit 0
        fi
        tick=$((tick + 1))
        sleep "$TICK"
    done
    exit 0
}

[ "${1:-}" = start ] || { echo 'Usage: start OWNER MARKER' >&2; exit 2; }
owner=${2:-}; marker=${3:-}
digits "$owner" && [ "$owner" -gt 1 ] || exit 2
case "$marker" in /*) ;; *) exit 2;; esac
[ -f "$marker" ] && [ ! -L "$marker" ] || { echo 'The session marker is missing.' >&2; exit 2; }
allowed || { echo 'Turning sleep off without a password is not allowed.' >&2; exit 3; }
identity=$(ps -p "$owner" -o lstart= 2>/dev/null)
program=$(ps -p "$owner" -o comm= 2>/dev/null)
program=${program##*/}
[ -n "$identity" ] && [ -n "$program" ] || { echo 'Burro is not running.' >&2; exit 2; }
if [ -d "$lock" ]; then
    old=$(head -c 16 "$lock/watcher" 2>/dev/null | tr -cd 0-9)
    if digits "$old" && kill -0 "$old" 2>/dev/null; then
        case "$(ps -p "$old" -o comm= 2>/dev/null)" in
        *sh) echo 'Another keep-awake session is still running or turning sleep back on.' >&2; exit 4;;
        esac
    fi
    # Left behind by a watchdog that was killed outright.
    rm -f "$lock/ready" "$lock/armed" "$lock/owner" "$lock/owner.tmp" "$lock/watcher"
    rmdir "$lock" 2>/dev/null
fi
mkdir -m 755 "$lock" 2>/dev/null || { echo 'Another keep-awake session is starting.' >&2; exit 4; }
# The watchdog starts first, so nothing below can leave sleep turned off without one.
watch "$owner" "$identity" "$program" "$marker" </dev/null >/dev/null 2>&1 &
watcher=$!
printf '%s\n' "$watcher" > "$lock/watcher"
waited=0
while [ ! -f "$lock/armed" ]; do
    if ! kill -0 "$watcher" 2>/dev/null || [ "$waited" -ge 100 ]; then
        kill "$watcher" 2>/dev/null
        rm -f "$lock/watcher"; rmdir "$lock" 2>/dev/null
        echo 'Could not start the watchdog.' >&2; exit 1
    fi
    waited=$((waited + 1)); sleep 0.1
done
if ! set_sleep 1; then
    kill "$watcher" 2>/dev/null
    echo 'Could not turn sleep off.' >&2; exit 1
fi
touch "$lock/ready"
# Stopped, or Burro gone, while waiting for authorization: undo at once.
if [ ! -f "$marker" ] || ! kill -0 "$owner" 2>/dev/null; then
    kill "$watcher" 2>/dev/null
    exit 1
fi
printf '%s %s\n' "$watcher" "$lock"
"""#

    /// Installs or removes the one sudoers rule (NoSleepBar's install-passwordless-toggle.sh, with Burro's file name).
    public static let setup = #"""
# Burro Keep Awake setup: lets one user run exactly `/usr/bin/pmset -a disablesleep 0` and `... 1`
# without a password, and nothing else.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
rule=/etc/sudoers.d/burro-keep-awake
case "${1:-}" in
install)
    user=${2:-}
    case "$user" in ''|-*|*[!A-Za-z0-9._-]*) echo 'Unexpected user name.' >&2; exit 2;; esac
    tmp=$(mktemp /tmp/burro-keep-awake.XXXXXX)
    trap 'rm -f "$tmp"' EXIT
    printf '%s\n' '# Lets Burro turn lid-closed sleep off and back on without a password; nothing else.' \
        "$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$tmp"
    visudo -cf "$tmp" >/dev/null
    install -o root -g wheel -m 0440 "$tmp" "$rule"
    ;;
remove)
    rm -f "$rule"
    ;;
*)
    exit 2
    ;;
esac
"""#

    /// Arguments for `/bin/sh` that run `script` with `arguments` as its positional parameters.
    public static func shellArguments(_ script: String, _ arguments: [String]) -> [String] {
        ["-c", script, processName] + arguments
    }
    /// The same as one shell command line, for `do shell script`.
    public static func commandLine(_ script: String, _ arguments: [String]) -> String {
        (["/bin/sh"] + shellArguments(script, arguments)).map(quoted).joined(separator: " ")
    }
    /// Single-quoted for /bin/sh: nothing inside is expanded.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
    /// `osascript` arguments that run `command` after the administrator prompt, showing `prompt`.
    /// The command travels as an argument, so it needs no AppleScript escaping.
    public static func administratorArguments(command: String, prompt: String) -> [String] {
        ["-e", "on run argv",
         "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges without altering line endings",
         "-e", "end run", command, prompt]
    }
}
