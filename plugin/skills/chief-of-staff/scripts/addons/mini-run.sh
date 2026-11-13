#!/bin/bash
# mini-run — run a HEAVY command (full test suite, tsc, a production build) on a configured remote runner host
# against THIS working tree, uncommitted changes included. Output streams back; exit code is the command's.
# Sessions stay on this machine; only heavy commands travel.
#
# Usage — from inside any repo or worktree under a $COS_REMOTE_LAUNCH_DIRS local dir:
#   mini-run [options] [--] <cmd> [args...]        e.g.  mini-run pnpm test:unit
#   mini-run [options] '<shell string>'            e.g.  mini-run 'pnpm typecheck && pnpm test:run src/x'
#   mini-run --status                              locks (ALIVE / STALE), job slots, disk free, load + memory on the remote
# Options:
#   --no-install   never run the package install remotely (default: install when the lockfile changed)
#   --install      force a frozen-lockfile install before the command
#   --no-deps      don't sync link:../<sibling> repos first
#   --force        run even a command that looks like it needs a DB / dev server / browser
#   --dry-run      print the mapping, excludes and steps; touch nothing
# Env: MINI_RUN_HOST (user@host; default $COS_REMOTE_USER@$COS_REMOTE_HOST or the inventory ip),
#      MINI_RUN_LOCK_TIMEOUT (s, 1800; also the wait for a job slot), COS_REMOTE_NODE (optional dir holding the
#      remote `node`; default: `node` on PATH),
#      MINI_RUN_MAX_JOBS (global job slots on the remote, all repos and machines; default 2),
#      MINI_RUN_MIN_AVAIL_PCT (don't start while the remote's available memory is below this %; default 20),
#      MINI_RUN_NO_MUX=1 (no shared ssh ControlMaster; auto-on after a mux error), MINI_RUN_CONTROL_PATH (test hook),
#      MINI_RUN_NO_LOCAL=1 (remote unreachable → exit 90 instead of the local fallback),
#      MINI_RUN_PROBE_TRIES (3) / MINI_RUN_PROBE_TIMEOUT (s, 15) / MINI_RUN_PROBE_PAUSE (s, 2): the reachability probe.
# Remote busy ≠ remote down: an answer on ANY probe attempt = up → queue for its lock / slot, never run here.
# Remote down: the command runs LOCALLY in the current dir, one at a time across all sessions on this machine
#   (~/.cache/mini-run/local.lock + pid; dead pid / pre-reboot lock reclaimed) — never N heavy runs at once here.
# Job slots: ~/.cache/mini-run/slots/slot-1..N on the remote (mkdir + pid; a dead pid's slot is reclaimed). A run
#   waits for a free slot AND enough memory before install+command, and gives the slot back on exit. Fair share: a
#   worker that already holds a slot waits while another worker is queued.
#
# Mapping: main checkout <LOCAL>/<repo> → ~/<REMOTE>/<repo>. A git worktree gets its own SIBLING dir
#   ~/<REMOTE>/<repo>--<branch> (sibling, so link:../<dep> still resolves), first created as a copy of the main dir
#   (node_modules included, so no cold install).
# Never sent: .env* (secrets stay here), .git, node_modules, dist, .next, .turbo, coverage, worktree dirs, logs.
#   A command that needs env/DB/tunnels/browser belongs on this machine — mini-run says so when the output looks like it.
# link:../<sibling> deps are synced first WITH their built dist, so the remote sees the build you see.
# Locks: ~/.cache/mini-run/locks/<dir>.lock holds pid (remote) + host + lpid (this machine's mini-run) + who. A waiter
#   breaks a lock whose remote pid is dead, whose holder pid is dead on the waiter's own machine, or that is empty /
#   pre-reboot, and logs "stale lock broken: <who>". A lock that cannot be created at all (disk full) fails at once.
# Exit: command's code · 90 usage/setup · 91 lock timeout · 92 sync failed · 93 install failed · 94 refused (needs local)
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/cos-os.sh"   # COS_PYTHON / cos_python
PROG=mini-run
say() { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die() { local c=$1; shift; say "$*"; exit "$c"; }
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
dt() { perl -e 'printf "%.1f", $ARGV[1]-$ARGV[0]' "$1" "$2"; }
# the session behind this job: chief worker name (spawn.sh) → claude session id
SESS=$(printf %s "${COS_WORKER:-${CLAUDE_CODE_SESSION_ID:+sid:${CLAUDE_CODE_SESSION_ID:0:8}}}" | tr -c 'A-Za-z0-9._:-' '-')
QWAIT="" TS="" TSD="" TR="" TE="" T0=""

NOINSTALL=0 FORCEINSTALL=0 NODEPS=0 FORCE=0 DRY=0 STATUS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) NOINSTALL=1; shift;; --install) FORCEINSTALL=1; shift;; --no-deps) NODEPS=1; shift;;
    --force) FORCE=1; shift;; --dry-run) DRY=1; shift;; --status) STATUS=1; shift;;
    -h|--help) sed -n '2,42p' "$0"; exit 0;;
    --) shift; break;; -*) die 90 "unknown option $1 (see --help)";; *) break;;
  esac
done

# ---------- config + host ----------
COS_CONFIG="${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}"
[ -f "$COS_CONFIG" ] && cos_source_config "$COS_CONFIG"
if [ -z "${MINI_RUN_HOST:-}${COS_REMOTE_HOST:-}" ] && { [ -z "${COS_INVENTORY:-}" ] || [ -z "${COS_REMOTE_HOST_KEY:-}" ]; }; then
  echo "addon mini-run not configured, skipping"; exit 0
fi
if [ -n "${MINI_RUN_HOST:-}" ]; then DEST="$MINI_RUN_HOST"
elif [ -n "${COS_REMOTE_HOST:-}" ]; then DEST="${COS_REMOTE_USER:-claude}@$COS_REMOTE_HOST"
else
  IP=$(cos_python -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['hosts'][sys.argv[2]]['ip'])" "$COS_INVENTORY" "$COS_REMOTE_HOST_KEY" 2>/dev/null) \
    || die 90 "cannot resolve hosts.$COS_REMOTE_HOST_KEY.ip in $COS_INVENTORY"
  DEST="${COS_REMOTE_USER:-claude}@$IP"
fi
# The master socket name carries the epoch HOUR: a master never lives longer than ~1 h + ControlPersist. A single
# long-lived master wedged after 18 h (leaked sessions, "Session open refused by peer"), so every run logged a mux
# error and fell back to a new ssh. Old masters idle out on their own (ControlPersist); no running job is cut off.
CM="${MINI_RUN_CONTROL_PATH:-$HOME/.ssh/cm-$(( $(date +%s) / 3600 ))-%C}"
# one shared master carries every concurrent mini-run's sessions; under load it fails with mm_send_fd / mux_client
# errors (sshd MaxSessions 10, macOS fd passing). On such an error: retry once WITHOUT the master, and stay off it.
MUXPAT='mux_client|mm_send_fd|ControlSocket|Control socket|administratively prohibited|Session open refused'
NOMUX=${MINI_RUN_NO_MUX:-0}
# a socket path over the unix limit (104, ssh adds a 17-char temp suffix; %C expands to 40) makes every ssh fail, which
# used to read as "remote unreachable" and ran the heavy job locally
[ $(( ${#CM} - 2 + 40 + 17 )) -le 103 ] || { [ "$NOMUX" = 1 ] || say "ControlPath too long for a unix socket — running without the shared master"; NOMUX=1; }
set_ssh() {
  if [ "$NOMUX" = 1 ]; then MUXO=(-o ControlPath=none); else MUXO=(-o ControlMaster=auto -o "ControlPath=$CM" -o ControlPersist=600); fi
  SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 "${MUXO[@]}")
  RSH="ssh -o BatchMode=yes -o ConnectTimeout=10 $(printf '%q ' "${MUXO[@]}")"
}
set_ssh
# nomux <stderr-file> → 0 (switched: retry) if it shows a mux error and we were still on the master
nomux() {
  [ "$NOMUX" = 0 ] && grep -qE "$MUXPAT" "$1" 2>/dev/null || return 1
  NOMUX=1; set_ssh; say "ssh mux error ($(grep -oE "$MUXPAT" "$1" | head -1)) — retrying without ControlMaster"
}

# ---------- the remote half (bash 3.2, runs as the remote user) ----------
read -r -d '' REMOTE <<'RSCRIPT'
set -u
mode=$1; shift
L=$HOME/.cache/mini-run/locks SL=$HOME/.cache/mini-run/slots; mkdir -p "$L" "$SL"
b64d() { base64 -d 2>/dev/null || base64 -D; }
mt() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s; }
boot() { local b; b=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+).*/\1/'); [ -n "$b" ] || b=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0) )); echo "$b"; }
penv() {   # penv <node-dir|-> : put the configured node dir (if any) first on PATH
  [ "$1" = - ] || export PATH="$1:$PATH"
  export PATH="$PATH:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  command -v node >/dev/null || echo "[mini-run] WARN no node on the remote runner (set COS_REMOTE_NODE)" >&2
  command -v pnpm >/dev/null || (cd /tmp && corepack enable pnpm >/dev/null 2>&1) || true
}
# memory: av = available % — macOS memory_pressure "free percentage" (counts reclaimable memory), else Linux
# MemAvailable/MemTotal; unknown → 100 (never blocks).
mem() {
  av=$(memory_pressure 2>/dev/null | awk -F': ' '/System-wide memory free percentage/{gsub(/%/,"",$2); print $2+0}'); msrc="memory_pressure"
  case "$av" in ''|*[!0-9]*) av=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if (t) printf "%d", a*100/t}' /proc/meminfo 2>/dev/null); msrc="/proc/meminfo MemAvailable";; esac
  case "$av" in ''|*[!0-9]*) av=100; msrc="unknown";; esac
}
# the client's keepalive never writes: stdin readable = EOF = that mini-run is gone, so a queued waiter stops waiting
gone() { perl -e 'vec($r,0,1)=1; exit(select($r,undef,undef,0)>0 ? 0 : 1)'; }
case "$mode" in
lock)   # lock <dir> <timeout> <who> [main-dir-to-clone] [holder-host] [holder-pid]
  dir=$HOME/$1 tmo=$2 who=$3 main=${4:-} lh=${5:-} lp=${6:-}
  ld="$L/$(printf %s "$1" | tr '/' '_').lock"; t0=$(date +%s); seen=init
  bt=$(boot)
  brk() { echo "BROKE $1: $(cat "$ld/who" 2>/dev/null || echo empty)"; rm -rf "$ld"; }
  free() { df -h "$HOME" | awk 'NR==2{print $4}'; }
  while ! e=$(mkdir "$ld" 2>&1); do
    # mkdir failed but no lock dir = not "busy": disk full / permissions. Waiting would only hit the timeout.
    [ -d "$ld" ] || { echo "LOCKFAIL ${e##*: } (remote disk free: $(free))"; exit 95; }
    h=$(cat "$ld/pid" 2>/dev/null)
    if [ -n "$h" ] && ! kill -0 "$h" 2>/dev/null; then brk "holder pid $h dead on the remote"; continue; fi
    if [ "$(mt "$ld")" -lt "$bt" ]; then brk "held from before the remote rebooted"; continue; fi   # pid reused
    if [ -z "$h" ] && [ $(( $(date +%s) - $(mt "$ld") )) -gt 30 ]; then brk "empty holder"; continue; fi
    # one WAIT line per holder: <remote-pid> <holder-host> <holder-pid> <who>; the waiting machine checks its own pids
    [ "$seen" = "$h" ] || { echo "WAIT ${h:--} $(cat "$ld/host" 2>/dev/null || echo -) $(cat "$ld/lpid" 2>/dev/null || echo -) $(cat "$ld/who" 2>/dev/null)"; seen=$h; }
    [ $(( $(date +%s) - t0 )) -lt "$tmo" ] || { echo "TIMEOUT"; exit 91; }
    gone && exit 0
    sleep 2
  done
  trap 'rm -rf "$ld"' EXIT; trap 'exit 1' HUP TERM INT
  echo $$ > "$ld/pid"; printf '%s\n' "$lh" > "$ld/host"; printf '%s\n' "$lp" > "$ld/lpid"
  printf '%s since %s\n' "$who" "$(date '+%H:%M:%S')" > "$ld/who" || { echo "LOCKFAIL cannot write holder (remote disk free: $(free))"; exit 95; }
  waited=$(( $(date +%s) - t0 ))
  if [ ! -d "$dir" ] && [ -n "$main" ] && [ -d "$HOME/$main" ]; then
    # cp errors must not reach stdout: a garbled "LOCKED" line left the client waiting forever while holding the lock
    e=$( { cp -cR "$HOME/$main" "$dir" 2>/dev/null || cp -R "$HOME/$main" "$dir"; } 2>&1 >/dev/null | tail -1)
    if [ -z "$e" ]; then rm -rf "$dir/.git"; echo "CLONED $main"; else rm -rf "$dir"; echo "CLONEFAIL ${e##*: } (remote disk free: $(free))"; exit 95; fi
  fi
  e=$(mkdir -p "$dir" 2>&1) || { echo "LOCKFAIL ${e##*: } (remote disk free: $(free))"; exit 95; }
  echo "LOCKED $waited"
  cat >/dev/null
  ;;
break)  # break <dir> <remote-pid> — free a lock whose holder process died on its own machine (only if the holder is unchanged)
  ld="$L/$(printf %s "$1" | tr '/' '_').lock"
  [ "$(cat "$ld/pid" 2>/dev/null)" = "$2" ] || { echo "CHANGED"; exit 0; }
  kill -TERM "$2" 2>/dev/null; sleep 1; kill -0 "$2" 2>/dev/null && kill -KILL "$2" 2>/dev/null
  [ "$(cat "$ld/pid" 2>/dev/null)" = "$2" ] && rm -rf "$ld"; echo "BROKEN"
  ;;
check)  # check <dir> <node-dir> <force-install>
  dir=$HOME/$1 nv=$2 fi=$3; cd "$dir" || exit 90; penv "$nv"
  if [ -f pnpm-lock.yaml ]; then pm=pnpm; elif [ -f package-lock.json ]; then pm=npm; else pm=none; fi
  want="$pm $(node -v 2>/dev/null) $(cat pnpm-lock.yaml package-lock.json package.json pnpm-workspace.yaml 2>/dev/null | shasum | cut -c1-40)"
  have=$(cat node_modules/.mini-run-install 2>/dev/null)
  if [ "$pm" != none ] && { [ "$fi" = 1 ] || [ "$want" != "$have" ]; }; then echo "INSTALL $pm"; else echo "INSTALL no"; fi
  ;;
run)    # run <dir> <subdir> <node-dir> <install:no|pnpm|npm> <cmd-b64> [max-jobs] [timeout] [min-avail-pct] [who]
  dir=$HOME/$1 sub=$2 nv=$3 inst=$4 cmd=$(printf %s "$5" | b64d); cd "$dir" || exit 90
  # global job slot + memory admission (too many heavy jobs at once can hang the remote)
  mj=${6:-2} tmo=${7:-1800} minav=${8:-20} who=${9:-?}; t0=$(date +%s); said=""; slot=""
  bt=$(boot)
  # fair share: a worker waiting in the queue leaves a marker; a worker that already holds a slot
  # waits while another worker's marker is fresh (< 30 s), so one worker's batch cannot take both slots.
  me=$(printf %s "$who" | tr -c 'A-Za-z0-9._-' _); wd=$HOME/.cache/mini-run/waiting; mkdir -p "$wd"; mk=$wd/$me
  trap '[ -z "$slot" ] || rm -rf "$slot"; rm -f "$mk"' EXIT; trap 'exit 1' HUP TERM INT
  while :; do
    mem; touch "$mk"
    mine=$(cat "$SL"/slot-*/who 2>/dev/null | awk -v w="$who" '$1==w' | wc -l | tr -d ' '); others=0
    for f in "$wd"/*; do [ -f "$f" ] || continue; [ "$(basename "$f")" = "$me" ] && continue
      [ $(( $(date +%s) - $(mt "$f") )) -lt 30 ] && others=$((others+1)); done
    fair=0; [ "${mine:-0}" -gt 0 ] && [ "$others" -gt 0 ] && fair=1
    if [ "${av:-0}" -ge "$minav" ] && [ "$fair" = 0 ]; then
      i=1
      while [ $i -le "$mj" ]; do
        sd=$SL/slot-$i
        if mkdir "$sd" 2>/dev/null; then echo $$ > "$sd/pid"; printf '%s since %s\n' "$who" "$(date '+%H:%M:%S')" > "$sd/who"; slot=$sd; break; fi
        h=$(cat "$sd/pid" 2>/dev/null)
        if [ -n "$h" ] && ! kill -0 "$h" 2>/dev/null; then rm -rf "$sd"; continue; fi
        sm=$(mt "$sd")
        if [ "$sm" -lt "$bt" ]; then rm -rf "$sd"; continue; fi   # from before the last reboot (pid may be reused)
        if [ -z "$h" ] && [ $(( $(date +%s) - sm )) -gt 30 ]; then rm -rf "$sd"; continue; fi
        i=$((i+1))
      done
      [ -z "$slot" ] || { rm -f "$mk"; break; }
      why="$mj/$mj job slots busy ($(cat "$SL"/slot-*/who 2>/dev/null | tr '\n' ';' | sed 's/;$//; s/;/; /g'))"; k=slots
    elif [ "$fair" = 1 ] && [ "${av:-0}" -ge "$minav" ]; then why="fair share: $who already holds a slot while $others other worker(s) wait"; k=fair
    else why="remote memory low (${av}% free, need ${minav}% — ${msrc})"; k=mem; fi
    [ "$said" = "$k" ] || { echo "[mini-run] queued: $why" >&2; said=$k; }
    [ $(( $(date +%s) - t0 )) -lt "$tmo" ] || { echo "[mini-run] gave up after ${tmo}s waiting for a job slot / memory" >&2; exit 91; }
    gone && exit 1
    sleep 3
  done
  [ -z "$said" ] || echo "[mini-run] got $(basename "$slot") after $(( $(date +%s) - t0 ))s" >&2
  penv "$nv"
  if [ "$inst" != no ]; then
    echo "[mini-run] $inst install (lockfile changed or first run) …" >&2
    if [ "$inst" = pnpm ]; then pnpm install --frozen-lockfile --config.confirmModulesPurge=false >&2 || exit 93
    else npm ci >&2 || exit 93; fi
    want="$inst $(node -v 2>/dev/null) $(cat pnpm-lock.yaml package-lock.json package.json pnpm-workspace.yaml 2>/dev/null | shasum | cut -c1-40)"
    printf '%s' "$want" > node_modules/.mini-run-install
  fi
  [ -z "$sub" ] || cd "$sub" || exit 90
  set -m
  /bin/bash -c "$cmd" </dev/null &
  pid=$!
  ( cat >/dev/null; kill -TERM -- -"$pid" 2>/dev/null; sleep 5; kill -KILL -- -"$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!; set +m
  wait "$pid"; rc=$?
  exec 2>/dev/null; kill -- -"$w"
  exit $rc
  ;;
status)
  # LK <state> <remote-pid> <holder-host> <holder-pid> <dir> <who> — the client adds the holder-pid check for its own host
  n=0; for d in "$L"/*.lock; do [ -d "$d" ] || continue; n=$((n+1)); h=$(cat "$d/pid" 2>/dev/null)
    if [ -z "$h" ]; then s="STALE(empty-holder)"; elif kill -0 "$h" 2>/dev/null; then s=ALIVE; else s="STALE(remote-pid-dead)"; fi
    echo "LK $s ${h:--} $(cat "$d/host" 2>/dev/null || echo -) $(cat "$d/lpid" 2>/dev/null || echo -) $(basename "$d" .lock | tr '_' '/') $(cat "$d/who" 2>/dev/null)"; done
  [ $n = 0 ] && echo "no locks held"
  echo "disk free: $(df -h "$HOME" | awk 'NR==2{print $4" ("$5" used)"}')"
  n=0; for d in "$SL"/slot-*; do [ -d "$d" ] || continue; n=$((n+1)); echo "$(basename "$d"): $(cat "$d/who" 2>/dev/null) pid $(cat "$d/pid" 2>/dev/null)"; done
  [ $n = 0 ] && echo "no job slots held"
  mem; echo "load: $(uptime | sed 's/.*load averages*: *//') · memory free: ${av}% (${msrc}) · admission needs ${1:-20}%"
  ;;
esac
RSCRIPT
RB64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
rcmd() { # the remote command line for <mode> args...   (args are regex-checked paths / b64 / numbers)
  local q=""; for a in "$@"; do q="$q $(printf '%q' "$a")"; done
  printf '%s' "/bin/bash -c \"\$(printf %s $RB64 | { base64 -d 2>/dev/null || base64 -D; })\" mini-run-remote$q"
}
rcall() { # retries once without the master on a mux error (RCALL_NORETRY=1 → return 199 instead, stdin was consumed)
  # ssh -n: never read the CALLER's stdin (a loop, a pipe or a tty of the calling shell); only `recv` (RCALL_STDIN=1) needs it
  local e rc n=(-n); [ "${RCALL_STDIN:-0}" = 1 ] && n=(); e=$(mktemp -t mini-run-e.XXXXXX)
  "${SSH[@]}" ${n[@]+"${n[@]}"} "$DEST" "$(rcmd "$@")" 2>"$e"; rc=$?
  if [ $rc -ne 0 ] && nomux "$e"; then
    if [ "${RCALL_NORETRY:-0}" = 1 ]; then rm -f "$e"; return 199; fi
    "${SSH[@]}" ${n[@]+"${n[@]}"} "$DEST" "$(rcmd "$@")" 2>"$e"; rc=$?
  elif [ $rc = 0 ]; then nomux "$e" >/dev/null 2>&1 || true; fi
  cat "$e" >&2; rm -f "$e"; return $rc
}

if [ "$STATUS" = 1 ]; then
  SMIN=${MINI_RUN_MIN_AVAIL_PCT:-20}; [[ "$SMIN" =~ ^[0-9]+$ ]] || die 90 "MINI_RUN_MIN_AVAIL_PCT must be a number"
  # status never runs anything locally; an ssh failure (255) under load is retried like the probe, then reported
  SN=${MINI_RUN_PROBE_TRIES:-3}; [[ "$SN" =~ ^[1-9][0-9]*$ ]] || SN=3; si=1
  while ST=$(rcall status "$SMIN"); src=$?; [ $src = 255 ] && [ $si -lt "$SN" ]; do
    say "status: ssh failed (try $si/$SN) — remote may be busy, retrying"; si=$((si+1)); sleep "${MINI_RUN_PROBE_PAUSE:-2}"; done
  [ $src = 0 ] || exit $src
  ME=$(hostname -s)
  printf '%s\n' "$ST" | while read -r tag s rp hh hp rest; do
    [ "$tag" = LK ] || { printf '%s %s %s %s %s %s\n' "$tag" "$s" "$rp" "$hh" "$hp" "$rest" | sed 's/ *$//'; continue; }
    # the holder's own machine: a dead mini-run there means the lock is stale even while its mini-side process lingers
    if [ "$s" = ALIVE ] && [ "$hh" = "$ME" ] && [ "$hp" != - ] && ! kill -0 "$hp" 2>/dev/null; then s="STALE(holder-pid-$hp-dead-on-$hh)"; fi
    echo "$s ${rest%% *}: ${rest#* } (remote pid $rp)"
  done
  exit 0
fi
[ $# -gt 0 ] || die 90 "no command. Usage: mini-run [--no-install|--install|--no-deps|--force|--dry-run] <cmd> [args…]"

# ---------- which repo, which remote dir ----------
command -v git >/dev/null || die 90 "git not found"
G() { command git "$@"; }
TOP=$(G rev-parse --show-toplevel 2>/dev/null) || die 90 "not inside a git repo — cd into the repo (or worktree) first"
SUB=$(G rev-parse --show-prefix); SUB=${SUB%/}
COMMON=$(G rev-parse --path-format=absolute --git-common-dir)
GITDIR=$(G rev-parse --path-format=absolute --git-dir)
MAIN=$(cd "$(dirname "$COMMON")" && pwd -P)
TOPP=$(cd "$TOP" && pwd -P)
MAP=""; LROOT=""
IFS=':' read -r -a PAIRS <<< "${COS_REMOTE_LAUNCH_DIRS:-}"
for a in ${PAIRS[@]+"${PAIRS[@]}"}; do
  l=${a%%=*}; r=${a#*=}; lp=$(cd "$l" 2>/dev/null && pwd -P) || continue
  case "$MAIN/" in "$lp"/?*) LROOT=$lp; MAP=$r;; esac
done
[ -n "$MAP" ] || die 90 "$MAIN is not under a mapped dir of COS_REMOTE_LAUNCH_DIRS (${COS_REMOTE_LAUNCH_DIRS:-unset})"
REPO=${MAIN#"$LROOT"/}
case "$REPO" in */*) die 90 "nested repo $REPO — only top-level repos of $LROOT are mapped";; esac
SAFE='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
if [ "$GITDIR" != "$COMMON" ] || [ "$TOPP" != "$MAIN" ]; then   # a worktree
  BR=$(G symbolic-ref --short -q HEAD || basename "$TOPP")
  BR=$(printf %s "$BR" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')
  RDIR="$MAP/$REPO--$BR"; CLONE_FROM="$MAP/$REPO"
else
  RDIR="$MAP/$REPO"; CLONE_FROM=""
fi
for p in "$RDIR" "${SUB:-x}"; do [[ "$p" =~ $SAFE ]] && [[ "$p" != *..* ]] || die 90 "unsafe path '$p'"; done
MAXJ=${MINI_RUN_MAX_JOBS:-2} MINAV=${MINI_RUN_MIN_AVAIL_PCT:-20} LTMO=${MINI_RUN_LOCK_TIMEOUT:-1800}
for n in "$MAXJ" "$MINAV" "$LTMO"; do [[ "$n" =~ ^[0-9]+$ ]] || die 90 "MINI_RUN_MAX_JOBS / MINI_RUN_MIN_AVAIL_PCT / MINI_RUN_LOCK_TIMEOUT must be numbers"; done
[ "$MAXJ" -ge 1 ] || die 90 "MINI_RUN_MAX_JOBS must be >= 1"
NODEV=${COS_REMOTE_NODE:--}
[[ "$NODEV" =~ ^[A-Za-z0-9._/~-]+$ ]] && [[ "$NODEV" != *..* ]] || die 90 "bad COS_REMOTE_NODE '$NODEV'"

# ---------- the command ----------
if [ $# -eq 1 ]; then CMD=$1; else CMD=$(printf '%q ' "$@"); CMD=${CMD% }; fi
if [ "$FORCE" = 0 ]; then
  case " $CMD " in
    *" dev "*|*":dev"*|*"next dev"*|*"db:"*|*"drizzle-kit"*|*"playwright"*|*"test:e2e"*|*"test:integration"*|*" start "*|*"migrate"*)
      die 94 "'$CMD' looks like it needs a DB, dev server, tunnel or browser — run it on this machine (or --force if it doesn't)";;
  esac
fi
CMDB64=$(printf '%s' "$CMD" | base64 | tr -d '\n')

# ---------- excludes ----------
EXF=$(mktemp -t mini-run-ex.XXXXXX); LOGF=$(mktemp -t mini-run-log.XXXXXX); DEPEX=$(mktemp -t mini-run-dex.XXXXXX)
LOCKPIDS=""
LOCALLOCK=""
cleanup() { for p in $LOCKPIDS; do kill "$p" 2>/dev/null; done; [ -z "$LOCALLOCK" ] || rm -rf "$LOCALLOCK"; rm -f "$EXF" "$DEPEX" "$LOGF" "$LOGF".*; }
# HUP is ignored: a background run (run_in_background, `&`) gets SIGHUP when its parent shell exits, and the old
# `trap 'exit 143' HUP` killed it at once. INT / TERM still stop the job and free the lock and slot.
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap '' HUP
cat > "$DEPEX" <<'EOF'
.git
.env*
node_modules
.next
.turbo
coverage
.pnpm-store
*.tsbuildinfo
.DS_Store
*.log
*.rdb
/.claude/worktrees/
/.worktrees/
/trees/
/graphify-out/
/playwright-report/
/test-results/
EOF
{ cat "$DEPEX"; echo dist; } > "$EXF"

# ---------- link:../<sibling> deps ----------
DEPS=""
if [ "$NODEPS" = 0 ] && [ -f "$TOPP/package.json" ]; then
  DEPS=$(cos_python - "$TOPP/package.json" <<'PY' | sort -u
import json,sys
p=json.load(open(sys.argv[1]))
for k in ("dependencies","devDependencies","optionalDependencies"):
    for v in (p.get(k) or {}).values():
        if isinstance(v,str) and v.startswith("link:../"):
            s=v[len("link:../"):].split("/")[0]
            if s and s!="..": print(s)
PY
)
fi

if [ "$DRY" = 1 ]; then
  say "host $DEST · node ${COS_REMOTE_NODE:-on PATH}"
  say "repo $REPO · local $TOPP${SUB:+ (cwd $SUB)} → remote ~/$RDIR${CLONE_FROM:+ (first run: copy of ~/$CLONE_FROM)}"
  for d in $DEPS; do say "dep  $LROOT/$d → ~/$MAP/$d (with dist)"; done
  say "excludes: $(tr '\n' ' ' < "$EXF")"
  say "command: $CMD"
  exit 0
fi

# ssh clients of a mini-run that was SIGKILLed are re-parented to init (ppid 1) and hold a session on the shared master
# for hours; a live mini-run's ssh always has a parent. Reap them so they cannot starve the master.
reap_orphans() {
  ps -A -ww -o pid=,ppid=,args= 2>/dev/null | awk '$2==1 && /ssh -o BatchMode=yes/ && /mini-run-remote/ {print $1}' | while read -r op; do
    kill "$op" 2>/dev/null && say "reaped orphaned ssh $op (its mini-run was killed)"; done; }
reap_orphans
keepalive() { while kill -0 $$ 2>/dev/null; do sleep 2; done; }

# ---------- remote down → run LOCALLY, serialized (parallel local builds can freeze this machine) ----------
# A busy remote is not a down remote: it is UP if it answers on ANY of MINI_RUN_PROBE_TRIES attempts (default 3,
# ConnectTimeout MINI_RUN_PROBE_TIMEOUT s, default 15, MINI_RUN_PROBE_PAUSE s between, default 2). Busy = up → queue.
probe_once() { local e rc t=$1; e=$(mktemp -t mini-run-e.XXXXXX); ssh -o ConnectTimeout="$t" "${SSH[@]:1}" "$DEST" true </dev/null >/dev/null 2>"$e"; rc=$?
  if nomux "$e"; then ssh -o ConnectTimeout="$t" "${SSH[@]:1}" "$DEST" true </dev/null >/dev/null 2>&1; rc=$?; fi; rm -f "$e"; return $rc; }
probe() { local n=${MINI_RUN_PROBE_TRIES:-3} t=${MINI_RUN_PROBE_TIMEOUT:-15} p=${MINI_RUN_PROBE_PAUSE:-2} i=1
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=3; [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=15; [[ "$p" =~ ^[0-9]+$ ]] || p=2
  while :; do
    probe_once "$t" && { [ $i = 1 ] || say "remote answered on probe $i/$n — busy, not down: using the remote"; return 0; }
    [ $i -lt "$n" ] || return 1
    say "remote probe $i/$n failed (ConnectTimeout ${t}s) — retrying in ${p}s before any local fallback"
    i=$((i+1)); sleep "$p"
  done; }
if [ "${MINI_DOWN:-0}" = 1 ] || ! probe; then
  [ "${MINI_RUN_NO_LOCAL:-0}" = 1 ] && die 90 "remote runner unreachable at $DEST (MINI_RUN_NO_LOCAL=1)."
  LD="$HOME/.cache/mini-run/local.lock"; mkdir -p "$(dirname "$LD")"; T0=$(now); W0=$(date +%s); said=0
  LBT=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+).*/\1/'); [ -n "$LBT" ] || LBT=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0) ))
  while ! mkdir "$LD" 2>/dev/null; do
    h=$(cat "$LD/pid" 2>/dev/null); m=$(stat -f %m "$LD" 2>/dev/null || stat -c %Y "$LD" 2>/dev/null || date +%s)
    if [ -n "$h" ] && ! kill -0 "$h" 2>/dev/null; then rm -rf "$LD"; continue; fi
    if [ "$m" -lt "$LBT" ] || { [ -z "$h" ] && [ $(( $(date +%s) - m )) -gt 30 ]; }; then rm -rf "$LD"; continue; fi
    [ $said = 1 ] || { say "remote down — queued locally behind $(cat "$LD/who" 2>/dev/null)"; said=1; }
    [ $(( $(date +%s) - W0 )) -lt "$LTMO" ] || die 91 "local lock timeout after ${LTMO}s (remote down)"
    sleep 2
  done
  LOCALLOCK=$LD; echo $$ > "$LD/pid"; printf '%s since %s\n' "$(whoami)-pid$$-$REPO${SESS:+-$SESS}" "$(date '+%H:%M:%S')" > "$LD/who"
  say "remote runner unreachable at $DEST — running LOCALLY in $PWD (serialized, 1 at a time)"
  TR=$(now); /bin/bash -c "$CMD" </dev/null & LPID=$!; LOCKPIDS="$LOCKPIDS $LPID"
  wait "$LPID"; RC=$?; TE=$(now)
  say "remote unreachable — ran LOCALLY (serialized, 1 at a time) · queue $(dt "$T0" "$TR")s · run $(dt "$TR" "$TE")s · exit $RC"
  exit "$RC"
fi
# take_lock <remote-dir> [clone-from] → sets LOCKWAIT; lock is held until the ssh (pid appended to LOCKPIDS) dies
take_lock() {
  local out; out=$(mktemp -t mini-run-lk.XXXXXX); rm -f "$out"; : > "$out"
  local rc; rc=$(rcmd lock "$1" "${MINI_RUN_LOCK_TIMEOUT:-1800}" "$(whoami)@$(hostname -s)-pid$$-$REPO${SESS:+-$SESS}" "${2:-}" "$(hostname -s)" "$$")
  "${SSH[@]}" "$DEST" "$rc" < <(keepalive) > "$out" 2>&1 &   # $! = the ssh itself, so killing it frees the lock
  local pid=$! lastw="" broke=0 tried="" wp="" wh="" wl="" ww="" me; me=$(hostname -s)
  LOCKPIDS="$LOCKPIDS $pid"
  while :; do
    if grep -q '^LOCKED' "$out"; then LOCKWAIT=$(sed -n 's/^LOCKED //p' "$out"); grep -q '^CLONED' "$out" && say "first run for this worktree: copied ~/$2 on the remote"; rm -f "$out"; return 0; fi
    # never rewrite $out (sed -i): the ssh keeps writing to the old inode and LOCKED would be lost
    local nb; nb=$(grep -c '^BROKE ' "$out"); if [ "$nb" -gt "$broke" ]; then sed -n 's/^BROKE //p' "$out" | tail -n $((nb - broke)) | while read -r l; do say "stale lock broken: $l"; done; broke=$nb; fi
    local w; w=$(grep '^WAIT ' "$out" | tail -1)
    if [ -n "$w" ] && [ "$w" != "$lastw" ]; then
      lastw=$w; read -r _ wp wh wl ww <<< "$w"
      say "queued: ~/$1 busy${TLABEL:-} — ${ww:-holder unknown}"
    fi
    # holder ran on THIS machine and its mini-run is gone → free it now instead of waiting out the lock timeout
    if [ -n "$w" ] && [ "$wh" = "$me" ] && [ "$wl" != - ] && [ "$wp" != - ] && [ "$wp" != "$tried" ] && ! kill -0 "$wl" 2>/dev/null; then
      tried=$wp
      [ "$(rcall break "$1" "$wp" </dev/null 2>/dev/null)" = BROKEN ] && say "stale lock broken: ${ww:-pid $wl} (pid $wl gone on $wh)"
    fi
    if grep -qE '^(LOCK|CLONE)FAIL ' "$out"; then say "lock on ~/$1 failed: $(sed -nE 's/^(LOCK|CLONE)FAIL //p' "$out" | tail -1)"; rm -f "$out"; exit 90; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      if ! grep -q TIMEOUT "$out" && nomux "$out"; then rm -f "$out"; take_lock "$@"; return; fi
      grep -q TIMEOUT "$out" && { rm -f "$out"; die 91 "lock timeout on ~/$1 after ${MINI_RUN_LOCK_TIMEOUT:-1800}s"; }
      say "lock ssh failed: $(tail -3 "$out")"; rm -f "$out"; exit 90
    fi
    sleep 0.3
  done
}
sync_dir() { # sync_dir <local> <remote-rel> <exclude-file>
  local e rc; e=$(mktemp -t mini-run-e.XXXXXX)
  rsync -a --delete -e "$RSH" --exclude-from="$3" "$1/" "$DEST:$2/" 2>"$e"; rc=$?
  if [ $rc -ne 0 ] && nomux "$e"; then rsync -a --delete -e "$RSH" --exclude-from="$3" "$1/" "$DEST:$2/" 2>"$e"; rc=$?; fi
  cat "$e" >&2; rm -f "$e"; return $rc
}

T0=$(now)
# 1. sibling deps (locked only while syncing)
for d in $DEPS; do
  [ -d "$LROOT/$d" ] || { say "WARN link dep $d missing locally — skipped"; continue; }
  [[ "$d" =~ $SAFE ]] || die 90 "unsafe dep '$d'"
  LOCKPIDS_BEFORE=$LOCKPIDS; TLABEL=" (sync of link dep $d, which $REPO links to — not $REPO itself)"; take_lock "$MAP/$d"; TLABEL=""
  sync_dir "$LROOT/$d" "$MAP/$d" "$DEPEX" || die 92 "rsync of dep $d failed"
  for p in $LOCKPIDS; do case " $LOCKPIDS_BEFORE " in *" $p "*) ;; *) kill "$p" 2>/dev/null;; esac; done
  LOCKPIDS=$LOCKPIDS_BEFORE
done
# 2. the repo itself (lock held through the run)
take_lock "$RDIR" "$CLONE_FROM"; QWAIT=$LOCKWAIT
TS=$(now)
sync_dir "$TOPP" "$RDIR" "$EXF" || die 92 "rsync to ~/$RDIR failed"
TSD=$(now)
# 3. install needed?
INST=no
if [ "$NOINSTALL" = 0 ]; then
  CK=$(rcall check "$RDIR" "$NODEV" "$FORCEINSTALL") || die 90 "check on the remote runner failed"
  INST=$(printf '%s\n' "$CK" | sed -n 's/^INSTALL //p')
fi
# 4. run
TR=$(now)
# background + wait: a trap (Ctrl-C, kill) fires during `wait`, never during a foreground ssh
run_remote() {
  "${SSH[@]}" "$DEST" "$(rcmd run "$RDIR" "$SUB" "$NODEV" "$INST" "$CMDB64" "$MAXJ" "$LTMO" "$MINAV" "$(whoami)@$(hostname -s)-pid$$-$REPO${SESS:+-$SESS}")" < <(keepalive) > >(tee "$LOGF") 2>&1 &
  RUNPID=$!; LOCKPIDS="$LOCKPIDS $RUNPID"
  wait "$RUNPID"; RC=$?
}
run_remote
if [ "$RC" = 255 ]; then sleep 0.3; nomux "$LOGF" && run_remote; fi   # mux refused the session: the command never started
TE=$(now); sleep 0.3   # let tee flush
if [ "$RC" -ne 0 ] && grep -qiE 'DATABASE_URL|REDIS_URL|Invalid environment variables|Missing (required )?env|ECONNREFUSED 127\.0\.0\.1:(5432|6379|9000)|\.env(\.local)? not found|NEXTAUTH_SECRET' "$LOGF"; then
  say "this looks like it needs env / a DB / tunnels — mini-run never sends .env. Run it on this machine."
fi
[ "$RC" = 91 ] && say "no job slot / memory on the remote within ${LTMO}s — see mini-run --status"
[ "$RC" = 93 ] && say "install failed on the remote runner — see output above"
say "~/$RDIR · queue ${QWAIT}s · sync $(dt "$TS" "$TSD")s · run $(dt "$TR" "$TE")s${INST:+ (install: $INST)} · total $(dt "$T0" "$TE")s · exit $RC"
exit "$RC"
