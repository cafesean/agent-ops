#!/bin/bash
# mini-run — run a HEAVY command (full test suite, tsc, a production build) on a configured remote runner host
# against THIS working tree, uncommitted changes included. Output streams back; exit code is the command's.
# Sessions stay on this machine; only heavy commands travel.
#
# Usage — from inside any repo or worktree under a $COS_REMOTE_LAUNCH_DIRS local dir:
#   mini-run [options] [--] <cmd> [args...]        e.g.  mini-run pnpm test:unit
#   mini-run [options] '<shell string>'            e.g.  mini-run 'pnpm typecheck && pnpm test:run src/x'
#   mini-run --status                              locks held / waiting on the remote runner
# Options:
#   --no-install   never run the package install remotely (default: install when the lockfile changed)
#   --install      force a frozen-lockfile install before the command
#   --force        run even a command that looks like it needs a DB / dev server / browser
#   --dry-run      print the mapping, excludes and steps; touch nothing
# Env: MINI_RUN_HOST (user@host; default $COS_REMOTE_USER@$COS_REMOTE_HOST or the inventory ip),
#      MINI_RUN_LOCK_TIMEOUT (s, 1800), COS_REMOTE_NODE (optional dir holding the remote `node`; default: `node` on PATH).
#
# Mapping: main checkout <LOCAL>/<repo> → ~/<REMOTE>/<repo>. A git worktree gets its own sibling dir
#   ~/<REMOTE>/<repo>--<branch>, first created as a copy of the main dir (node_modules included, so no cold install).
# Never sent: .env* (secrets stay here), .git, node_modules, dist, .next, .turbo, coverage, worktree dirs, logs.
#   A command that needs env/DB/tunnels/browser belongs on this machine — mini-run says so when the output looks like it.
# Exit: command's code · 90 usage/setup · 91 lock timeout · 92 sync failed · 93 install failed · 94 refused (needs local)
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/cos-os.sh"   # COS_PYTHON / cos_python
PROG=mini-run
say() { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die() { local c=$1; shift; say "$*"; exit "$c"; }
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
dt() { perl -e 'printf "%.1f", $ARGV[1]-$ARGV[0]' "$1" "$2"; }

NOINSTALL=0 FORCEINSTALL=0 FORCE=0 DRY=0 STATUS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) NOINSTALL=1; shift;; --install) FORCEINSTALL=1; shift;;
    --force) FORCE=1; shift;; --dry-run) DRY=1; shift;; --status) STATUS=1; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    --) shift; break;; -*) die 90 "unknown option $1 (see --help)";; *) break;;
  esac
done

# ---------- config + host ----------
COS_CONFIG="${AGENT_OPS_CONFIG:-$HOME/.claude/agent-ops/config.env}"
[ -f "$COS_CONFIG" ] && . "$COS_CONFIG"
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
CM="$HOME/.ssh/cm-minirun-%C"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ControlMaster=auto -o "ControlPath=$CM" -o ControlPersist=600)
RSH="ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$CM -o ControlPersist=600"

# ---------- the remote half (bash 3.2, runs as the remote user) ----------
read -r -d '' REMOTE <<'RSCRIPT'
set -u
mode=$1; shift
L=$HOME/.cache/mini-run/locks; mkdir -p "$L"
b64d() { base64 -d 2>/dev/null || base64 -D; }
penv() {   # penv <node-dir|-> : put the configured node dir (if any) first on PATH
  [ "$1" = - ] || export PATH="$1:$PATH"
  export PATH="$PATH:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  command -v node >/dev/null || echo "[mini-run] WARN no node on the remote runner (set COS_REMOTE_NODE)" >&2
  command -v pnpm >/dev/null || (cd /tmp && corepack enable pnpm >/dev/null 2>&1) || true
}
case "$mode" in
lock)   # lock <dir> <timeout> <who> [main-dir-to-clone]
  dir=$HOME/$1 tmo=$2 who=$3 main=${4:-}
  ld="$L/$(printf %s "$1" | tr '/' '_').lock"; t0=$(date +%s); said=0
  while ! mkdir "$ld" 2>/dev/null; do
    h=$(cat "$ld/pid" 2>/dev/null)
    if [ -n "$h" ] && ! kill -0 "$h" 2>/dev/null; then rm -rf "$ld"; continue; fi
    if [ -z "$h" ] && [ $(( $(date +%s) - $(stat -f %m "$ld" 2>/dev/null || stat -c %Y "$ld" 2>/dev/null || date +%s) )) -gt 30 ]; then rm -rf "$ld"; continue; fi
    [ $said = 1 ] || { echo "WAIT $(cat "$ld/who" 2>/dev/null)"; said=1; }
    [ $(( $(date +%s) - t0 )) -lt "$tmo" ] || { echo "TIMEOUT"; exit 91; }
    sleep 2
  done
  echo $$ > "$ld/pid"; printf '%s since %s\n' "$who" "$(date '+%H:%M:%S')" > "$ld/who"
  trap 'rm -rf "$ld"' EXIT; trap 'exit 1' HUP TERM INT
  waited=$(( $(date +%s) - t0 ))
  if [ ! -d "$dir" ] && [ -n "$main" ] && [ -d "$HOME/$main" ]; then
    { cp -cR "$HOME/$main" "$dir" 2>/dev/null || cp -R "$HOME/$main" "$dir"; } && rm -rf "$dir/.git" && echo "CLONED $main"
  fi
  mkdir -p "$dir"
  echo "LOCKED $waited"
  cat >/dev/null
  ;;
check)  # check <dir> <node-dir> <force-install>
  dir=$HOME/$1 nv=$2 fi=$3; cd "$dir" || exit 90; penv "$nv"
  if [ -f pnpm-lock.yaml ]; then pm=pnpm; elif [ -f package-lock.json ]; then pm=npm; else pm=none; fi
  want="$pm $(node -v 2>/dev/null) $(cat pnpm-lock.yaml package-lock.json package.json pnpm-workspace.yaml 2>/dev/null | shasum | cut -c1-40)"
  have=$(cat node_modules/.mini-run-install 2>/dev/null)
  if [ "$pm" != none ] && { [ "$fi" = 1 ] || [ "$want" != "$have" ]; }; then echo "INSTALL $pm"; else echo "INSTALL no"; fi
  ;;
run)    # run <dir> <subdir> <node-dir> <install:no|pnpm|npm> <cmd-b64>
  dir=$HOME/$1 sub=$2 nv=$3 inst=$4 cmd=$(printf %s "$5" | b64d); cd "$dir" || exit 90; penv "$nv"
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
  n=0; for d in "$L"/*.lock; do [ -d "$d" ] || continue; n=$((n+1)); echo "$(basename "$d" .lock | tr '_' '/'): $(cat "$d/who" 2>/dev/null) pid $(cat "$d/pid" 2>/dev/null)"; done
  [ $n = 0 ] && echo "no locks held"
  echo "load: $(uptime | sed 's/.*load averages*: *//')"
  ;;
esac
RSCRIPT
RB64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
rcmd() { # the remote command line for <mode> args...   (args are regex-checked paths / b64 / numbers)
  local q=""; for a in "$@"; do q="$q $(printf '%q' "$a")"; done
  printf '%s' "/bin/bash -c \"\$(printf %s $RB64 | { base64 -d 2>/dev/null || base64 -D; })\" mini-run-remote$q"
}
rcall() { "${SSH[@]}" "$DEST" "$(rcmd "$@")"; }

if [ "$STATUS" = 1 ]; then rcall status; exit $?; fi
[ $# -gt 0 ] || die 90 "no command. Usage: mini-run [--no-install|--install|--force|--dry-run] <cmd> [args…]"

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
EXF=$(mktemp -t mini-run-ex.XXXXXX); LOGF=$(mktemp -t mini-run-log.XXXXXX)
LOCKPIDS=""
cleanup() { for p in $LOCKPIDS; do kill "$p" 2>/dev/null; done; rm -f "$EXF" "$LOGF" "$LOGF".*; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
cat > "$EXF" <<'EOF'
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
/playwright-report/
/test-results/
dist
EOF

if [ "$DRY" = 1 ]; then
  say "host $DEST · node ${COS_REMOTE_NODE:-on PATH}"
  say "repo $REPO · local $TOPP${SUB:+ (cwd $SUB)} → remote ~/$RDIR${CLONE_FROM:+ (first run: copy of ~/$CLONE_FROM)}"
  say "excludes: $(tr '\n' ' ' < "$EXF")"
  say "command: $CMD"
  exit 0
fi

keepalive() { while kill -0 $$ 2>/dev/null; do sleep 2; done; }
# take_lock <remote-dir> [clone-from] → sets LOCKWAIT; lock is held until the ssh (pid appended to LOCKPIDS) dies
take_lock() {
  local out; out=$(mktemp -t mini-run-lk.XXXXXX); rm -f "$out"; : > "$out"
  local rc; rc=$(rcmd lock "$1" "${MINI_RUN_LOCK_TIMEOUT:-1800}" "$(whoami)@$(hostname -s)-pid$$-$REPO" "${2:-}")
  "${SSH[@]}" "$DEST" "$rc" < <(keepalive) > "$out" 2>&1 &   # $! = the ssh itself, so killing it frees the lock
  local pid=$! waited=0
  LOCKPIDS="$LOCKPIDS $pid"
  while :; do
    if grep -q '^LOCKED' "$out"; then LOCKWAIT=$(sed -n 's/^LOCKED //p' "$out"); grep -q '^CLONED' "$out" && say "first run for this worktree: copied ~/$2 on the remote runner"; rm -f "$out"; return 0; fi
    if grep -q '^WAIT' "$out" && [ "$waited" = 0 ]; then say "queued: ~/$1 busy — $(sed -n 's/^WAIT //p' "$out")"; waited=1; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      grep -q TIMEOUT "$out" && { rm -f "$out"; die 91 "lock timeout on ~/$1 after ${MINI_RUN_LOCK_TIMEOUT:-1800}s"; }
      say "lock ssh failed: $(tail -3 "$out")"; rm -f "$out"; exit 90
    fi
    sleep 0.3
  done
}
sync_dir() { # sync_dir <local> <remote-rel> <exclude-file>
  rsync -a --delete -e "$RSH" --exclude-from="$3" "$1/" "$DEST:$2/"
}

T0=$(now)
# 1. the repo itself (lock held through the run)
take_lock "$RDIR" "$CLONE_FROM"; QWAIT=$LOCKWAIT
TS=$(now)
sync_dir "$TOPP" "$RDIR" "$EXF" || die 92 "rsync to ~/$RDIR failed"
TSD=$(now)
# 2. install needed?
INST=no
if [ "$NOINSTALL" = 0 ]; then
  CK=$(rcall check "$RDIR" "$NODEV" "$FORCEINSTALL") || die 90 "check on the remote runner failed"
  INST=$(printf '%s\n' "$CK" | sed -n 's/^INSTALL //p')
fi
# 3. run
TR=$(now)
# background + wait: a trap (Ctrl-C, kill) fires during `wait`, never during a foreground ssh
"${SSH[@]}" "$DEST" "$(rcmd run "$RDIR" "$SUB" "$NODEV" "$INST" "$CMDB64")" < <(keepalive) > >(tee "$LOGF") 2>&1 &
RUNPID=$!; LOCKPIDS="$LOCKPIDS $RUNPID"
wait "$RUNPID"; RC=$?
TE=$(now); sleep 0.3   # let tee flush
if [ "$RC" -ne 0 ] && grep -qiE 'DATABASE_URL|REDIS_URL|Invalid environment variables|Missing (required )?env|ECONNREFUSED 127\.0\.0\.1:(5432|6379|9000)|\.env(\.local)? not found|NEXTAUTH_SECRET' "$LOGF"; then
  say "this looks like it needs env / a DB / tunnels — mini-run never sends .env. Run it on this machine."
fi
[ "$RC" = 93 ] && say "install failed on the remote runner — see output above"
say "~/$RDIR · queue ${QWAIT}s · sync $(dt "$TS" "$TSD")s · run $(dt "$TR" "$TE")s${INST:+ (install: $INST)} · total $(dt "$T0" "$TE")s · exit $RC"
exit "$RC"
