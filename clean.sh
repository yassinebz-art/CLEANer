#!/bin/bash
# clean — safe project, asset & system cleaner for macOS dev machines
# Designed to be aggressive about throwaway build artifacts and
# extra cautious with anything that could break a project or the OS.
#
# What it reclaims (the big ones on a typical dev Mac):
#   • Gradle caches incl. version dirs (~/.gradle/caches/9.x, 8.x …)  ← often 10–30 GB
#   • npm / yarn / pnpm / bun / pip / go / cargo / CocoaPods caches    ← often 5–15 GB
#   • Xcode DerivedData, DeviceSupport, SwiftPM, simulator junk
#   • Homebrew downloads, Docker build cache & unused images
#   • node_modules + per-project android/ios build artifacts
#   • Android Studio / JetBrains / VS Code caches, logs, QuickLook

# Safer defaults. We avoid `set -e` because the script intentionally
# tolerates many "not found" cases via if-checks.
set -u
set -o pipefail
IFS=$'\n\t'

# Colors
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
BLUE="\033[34m"
MAGENTA="\033[35m"
WHITE="\033[97m"
RESET="\033[0m"
BG_DARK="\033[48;5;235m"

CONFIG_FILE="$HOME/.cleanpc_config"
LOG_FILE="$HOME/.cleanpc.log"

# Projects that must NEVER be touched, no matter the mode or selection.
# Matched by folder name (basename) inside the projects dir.
ALWAYS_EXCLUDE=(
  "codepush-cli-v1"
)

# ─────────────────────────────────────────────────────────────
# CLI flags
# ─────────────────────────────────────────────────────────────
DRY_RUN=false
ASSUME_YES=false
AGGRESSIVE=false
SKIP_DOCKER=false
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run)     DRY_RUN=true ;;
    -y|--yes)         ASSUME_YES=true ;;
    -a|--aggressive)  AGGRESSIVE=true ;;
    --skip-docker)    SKIP_DOCKER=true ;;
    -h|--help)
      cat <<EOF
Usage: clean [options]

Options:
  -n, --dry-run     Show what would be deleted without deleting anything
  -y, --yes         Skip confirmation prompts
  -a, --aggressive  Also clear re-downloadable extras: Docker images/volumes,
                    Homebrew --prune=all, Xcode Archives, go/cargo module caches,
                    non-booted Simulator devices (app data inside them is lost)
      --skip-docker Don't touch Docker even in "clean all/system"
  -h, --help        Show this help

Config file: $CONFIG_FILE
Log file:    $LOG_FILE
EOF
      exit 0
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}
log "===== clean run started (dry_run=$DRY_RUN aggressive=$AGGRESSIVE) ====="

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
repeat_char() {
  local c="$1" n="$2" s=""
  [ "$n" -le 0 ] 2>/dev/null && { printf ''; return; }
  local i
  for ((i = 0; i < n; i++)); do s+="$c"; done
  printf '%s' "$s"
}

# ─────────────────────────────────────────────────────────────
# Arrow-key menu
#
# MENU_KINDS / MENU_LABELS / MENU_DESCS / MENU_MODES are parallel arrays.
# Kind "sep" is a non-selectable divider, "item" is a choice. Up/Down (or
# k/j) move, Enter picks, q or Esc aborts. Falls back to a numbered
# prompt when stdin is not a terminal.
# ─────────────────────────────────────────────────────────────
MENU_KINDS=()
MENU_LABELS=()
MENU_DESCS=()
MENU_MODES=()

menu_sep()  { MENU_KINDS+=("sep");  MENU_LABELS+=("$1"); MENU_DESCS+=("");   MENU_MODES+=(""); }
menu_item() { MENU_KINDS+=("item"); MENU_LABELS+=("$1"); MENU_DESCS+=("$2"); MENU_MODES+=("$3"); }

# Draw the menu; $1 = index of the highlighted row.
menu_render() {
  local cur="$1" i
  for i in "${!MENU_KINDS[@]}"; do
    if [ "${MENU_KINDS[$i]}" = "sep" ]; then
      if [ -n "${MENU_LABELS[$i]}" ]; then
        echo -e "  ${DIM}$(repeat_char '-' 20)${RESET} ${BOLD}${MAGENTA}${MENU_LABELS[$i]}${RESET} ${DIM}$(repeat_char '-' 20)${RESET}"
      else
        echo -e "  ${DIM}$(repeat_char '-' 58)${RESET}"
      fi
    elif [ "$i" = "$cur" ]; then
      printf "  ${BOLD}${CYAN}>${RESET} ${BOLD}${WHITE}%-24s${RESET} ${DIM}%s${RESET}\n" \
        "${MENU_LABELS[$i]}" "${MENU_DESCS[$i]}"
    else
      printf "    ${WHITE}%-24s${RESET} ${DIM}%s${RESET}\n" \
        "${MENU_LABELS[$i]}" "${MENU_DESCS[$i]}"
    fi
  done
}

# Run the picker. Echoes the chosen mode, or nothing if aborted.
menu_choose() {
  local total=${#MENU_KINDS[@]} cur=-1 i

  # Start on the first selectable row.
  for i in "${!MENU_KINDS[@]}"; do
    if [ "${MENU_KINDS[$i]}" = "item" ]; then cur=$i; break; fi
  done
  [ "$cur" -lt 0 ] && return 1

  # No terminal (piped input, CI): fall back to typing a number.
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    local n=0
    for i in "${!MENU_KINDS[@]}"; do
      [ "${MENU_KINDS[$i]}" = "item" ] || continue
      n=$((n + 1))
      printf "  %d) %s\n" "$n" "${MENU_LABELS[$i]}" >&2
    done
    local pick; read -r pick
    n=0
    for i in "${!MENU_KINDS[@]}"; do
      [ "${MENU_KINDS[$i]}" = "item" ] || continue
      n=$((n + 1))
      [ "$n" = "$pick" ] && { echo "${MENU_MODES[$i]}"; return 0; }
    done
    return 1
  fi

  # bash 3.2 (the macOS default) only accepts whole-second read timeouts,
  # so the escape-sequence wait has to be 1s there.
  local esc_wait=1
  [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && esc_wait="0.05"

  # Move to the next/previous selectable row, wrapping around.
  local step key rest
  printf '\033[?25l' >&2   # hide cursor
  menu_render "$cur" >&2
  while true; do
    IFS= read -rsn1 key < /dev/tty || break
    step=0
    case "$key" in
      $'\033')
        rest=""
        read -rsn2 -t "$esc_wait" rest < /dev/tty || true
        case "$rest" in
          '[A') step=-1 ;;
          '[B') step=1 ;;
          '')   printf '\033[?25h' >&2; return 2 ;;   # bare Esc = go back
        esac
        ;;
      k|K) step=-1 ;;
      j|J) step=1 ;;
      q|Q) printf '\033[?25h' >&2; return 1 ;;
      '')  printf '\033[?25h' >&2; echo "${MENU_MODES[$cur]}"; return 0 ;;
    esac

    if [ "$step" -ne 0 ]; then
      local next=$cur
      while true; do
        next=$(( (next + step + total) % total ))
        [ "${MENU_KINDS[$next]}" = "item" ] && break
        [ "$next" = "$cur" ] && break
      done
      cur=$next
    fi

    printf '\033[%dA' "$total" >&2   # rewind over the menu and redraw
    menu_render "$cur" >&2
  done
  printf '\033[?25h' >&2
  return 1
}

# ─────────────────────────────────────────────────────────────
# Arrow-key multi-select
#
# Space toggles the row under the cursor, a toggles everything, Enter
# confirms. Echoes the chosen indices, one per line.
#
# Exit codes are the navigation contract used everywhere in this script:
#   0 = confirmed   1 = quit (q)   2 = go back one step (Esc)
# ─────────────────────────────────────────────────────────────
MULTI_LABELS=()
MULTI_DESCS=()
MULTI_SEL=()

multi_reset() { MULTI_LABELS=(); MULTI_DESCS=(); MULTI_SEL=(); }
multi_item()  { MULTI_LABELS+=("$1"); MULTI_DESCS+=("$2"); MULTI_SEL+=("${3:-0}"); }

multi_render() {
  local cur="$1" i mark pointer
  for i in "${!MULTI_LABELS[@]}"; do
    if [ "${MULTI_SEL[$i]}" = "1" ]; then mark="${GREEN}[x]${RESET}"; else mark="${DIM}[ ]${RESET}"; fi
    if [ "$i" = "$cur" ]; then pointer="${BOLD}${CYAN}>${RESET}"; else pointer=" "; fi
    printf "  %b %b ${BOLD}${WHITE}%-30s${RESET} ${DIM}%s${RESET}\n" \
      "$pointer" "$mark" "${MULTI_LABELS[$i]}" "${MULTI_DESCS[$i]}"
  done
}

menu_multi_choose() {
  local total=${#MULTI_LABELS[@]} cur=0 i
  [ "$total" -eq 0 ] && return 1

  # No terminal: fall back to typing numbers / a.
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    local n=0 pick
    for i in "${!MULTI_LABELS[@]}"; do
      n=$((n + 1)); printf "  %d) %s\n" "$n" "${MULTI_LABELS[$i]}" >&2
    done
    read -r pick
    if [ "$pick" = "a" ] || [ "$pick" = "A" ]; then
      for i in "${!MULTI_LABELS[@]}"; do echo "$i"; done
    else
      local IFS=','; local nums=($pick); unset IFS
      for n in "${nums[@]}"; do
        n=$(printf '%s' "$n" | tr -d ' ')
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        [ "$n" -ge 1 ] && [ "$n" -le "$total" ] && echo "$((n - 1))"
      done
    fi
    return 0
  fi

  local esc_wait=1
  [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && esc_wait="0.05"

  printf '\033[?25l' >&2
  multi_render "$cur" >&2
  local key rest step any
  while true; do
    IFS= read -rsn1 key < /dev/tty || break
    step=0
    case "$key" in
      $'\033')
        rest=""
        read -rsn2 -t "$esc_wait" rest < /dev/tty || true
        case "$rest" in
          '[A') step=-1 ;;
          '[B') step=1 ;;
          '')   printf '\033[?25h' >&2; return 2 ;;   # bare Esc = go back
        esac
        ;;
      k|K) step=-1 ;;
      j|J) step=1 ;;
      ' ')
        if [ "${MULTI_SEL[$cur]}" = "1" ]; then MULTI_SEL[$cur]=0; else MULTI_SEL[$cur]=1; fi
        ;;
      a|A)
        any=0
        for i in "${!MULTI_SEL[@]}"; do [ "${MULTI_SEL[$i]}" = "0" ] && any=1 && break; done
        for i in "${!MULTI_SEL[@]}"; do MULTI_SEL[$i]=$any; done
        ;;
      q|Q) printf '\033[?25h' >&2; return 1 ;;
      '')
        printf '\033[?25h' >&2
        for i in "${!MULTI_SEL[@]}"; do
          [ "${MULTI_SEL[$i]}" = "1" ] && echo "$i"
        done
        return 0
        ;;
    esac

    if [ "$step" -ne 0 ]; then
      cur=$(( (cur + step + total) % total ))
    fi
    printf '\033[%dA' "$total" >&2
    multi_render "$cur" >&2
  done
  printf '\033[?25h' >&2
  return 1
}

# ─────────────────────────────────────────────────────────────
# Arrow-key Yes/No. Defaults to No, so Enter never destroys anything
# by accident. Returns 0 for yes, 1 for no.
# ─────────────────────────────────────────────────────────────
menu_yesno() {
  local prompt="$1" cur=1 ans   # 0 = yes, 1 = no
  echo -e "  ${BOLD}${prompt}${RESET}"

  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    read -r ans
    [[ "$ans" =~ ^[yY]$ ]] && return 0
    return 1
  fi

  local esc_wait=1
  [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && esc_wait="0.05"

  yesno_render() {
    local c="$1"
    if [ "$c" = "0" ]; then
      echo -e "  ${BOLD}${GREEN}> Yes${RESET}    ${DIM}No${RESET}"
    else
      echo -e "  ${DIM}  Yes${RESET}    ${BOLD}${RED}> No${RESET}"
    fi
  }

  printf '\033[?25l' >&2
  yesno_render "$cur" >&2
  local key rest
  while true; do
    IFS= read -rsn1 key < /dev/tty || break
    case "$key" in
      $'\033')
        rest=""
        read -rsn2 -t "$esc_wait" rest < /dev/tty || true
        case "$rest" in
          '[C'|'[B') cur=1 ;;
          '[D'|'[A') cur=0 ;;
          '') printf '\033[?25h' >&2; return 2 ;;   # bare Esc = go back
        esac
        ;;
      h|H|k|K) cur=0 ;;
      l|L|j|J) cur=1 ;;
      y|Y) printf '\033[?25h' >&2; yesno_render 0 >&2; return 0 ;;
      n|N|q|Q) printf '\033[?25h' >&2; yesno_render 1 >&2; return 1 ;;
      '')
        printf '\033[?25h' >&2
        [ "$cur" = "0" ] && return 0
        return 1
        ;;
    esac
    printf '\033[1A' >&2
    yesno_render "$cur" >&2
  done
  printf '\033[?25h' >&2
  return 1
}

# Join array elements for display: IFS=$'\n\t' would otherwise make
# "${arr[*]}" break across lines.
join_list() {
  local out="" e
  for e in "$@"; do
    if [ -z "$out" ]; then out="$e"; else out="$out, $e"; fi
  done
  printf '%s' "$out"
}

# A labeled section divider: ------------ LABEL ------------
group_divider() {
  local label="$1" width=58
  local text=" $label "
  local dashes=$((width - ${#text}))
  local left=$((dashes / 2))
  local right=$((dashes - left))
  [ "$left" -lt 0 ] && left=0
  [ "$right" -lt 0 ] && right=0
  echo -e "  ${DIM}$(repeat_char '-' "$left")${RESET}${BOLD}${MAGENTA}${text}${RESET}${DIM}$(repeat_char '-' "$right")${RESET}"
}

term_width() {
  local w
  w=$(tput cols 2>/dev/null) || w=80
  [ -z "$w" ] && w=80
  [ "$w" -gt 72 ] && w=72
  echo "$w"
}

# Boxed section header (replaces the old plain underline style).
header() {
  local title="$1"
  local w inner pad_total pad_left pad_right title_len
  w=$(term_width)
  inner=$((w - 2))
  title_len=${#title}
  pad_total=$((inner - title_len))
  [ "$pad_total" -lt 0 ] && pad_total=0
  pad_left=$((pad_total / 2))
  pad_right=$((pad_total - pad_left))
  echo ""
  echo -e "${CYAN}╭$(repeat_char '─' "$inner")╮${RESET}"
  echo -e "${CYAN}│${RESET}$(repeat_char ' ' "$pad_left")${BOLD}${WHITE}${title}${RESET}$(repeat_char ' ' "$pad_right")${CYAN}│${RESET}"
  echo -e "${CYAN}╰$(repeat_char '─' "$inner")╯${RESET}"
}

# Spinner around a command: shows a live frame while it runs, then a
# single ✅/⚠️ result line. Falls back to silent run when not a TTY.
spinner_run() {
  local label="$1"; shift
  if [ ! -t 1 ]; then
    "$@" >/dev/null 2>&1
    return $?
  fi
  "$@" >/dev/null 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r   ${CYAN}%s${RESET} %s" "${frames:$i:1}" "$label"
    i=$((( i + 1 ) % ${#frames}))
    sleep 0.08
  done
  wait "$pid"
  local status=$?
  printf "\r\033[K"
  return $status
}

dir_size() {
  if [ -d "$1" ] || [ -f "$1" ]; then
    du -sh "$1" 2>/dev/null | awk '{print $1}'
  else
    echo "0B"
  fi
}

# Paths we will REFUSE to recursively delete. Anything matching these
# (or being equal to them) gets rejected by safe_rm.
# Protect: filesystem roots, home, common system dirs, dotfiles roots.
PROTECTED_PATHS=(
  "/"
  "/Users"
  "/System"
  "/Library"
  "/Applications"
  "/private"
  "/etc"
  "/var"
  "/usr"
  "/bin"
  "/sbin"
  "/opt"
  "/tmp"
  "$HOME"
  "$HOME/Documents"
  "$HOME/Desktop"
  "$HOME/Downloads"
  "$HOME/Library"
  "$HOME/.ssh"
  "$HOME/.gnupg"
  "$HOME/.aws"
  "$HOME/.config"
  "$HOME/.gradle"          # we allow specific subdirs only
  "$HOME/.gradle/wrapper"  # holds Gradle distributions
  "$HOME/.android"         # AVDs, keystores
  "$HOME/.m2"
  "$HOME/.npm"
  "$HOME/.cocoapods"
  "$HOME/Library/Developer/Xcode"  # only specific subdirs allowed
)

# Inside ~/Library/Caches, NEVER touch these (data-loss risk or known
# misuse of the Caches dir for non-cache state).
PROTECTED_CACHE_PREFIXES=(
  "com.apple.keychainaccess"
  "com.apple.iCloudHelper"
  "com.apple.bird"          # iCloud Drive
  "com.apple.cloudd"
  "com.apple.Mail"
  "com.apple.mail"
  "com.apple.MobileSync"
  "com.apple.AddressBook"
  "com.apple.Notes"
  "com.apple.Photos"
  "com.apple.PhotoBoothApp"
  "com.apple.Music"
  "com.apple.Safari"        # bookmark/icon DB lives here on some setups
  "com.apple.WebKit"
  "com.apple.Messages"
  "com.apple.imessage"
  "com.apple.passd"
  "com.apple.akd"
  "com.apple.identityservicesd"
  "com.apple.appleaccount"
  "com.apple.AppleAccountService"
  "1Password"
  "com.1password"
  "com.agilebits"
  "com.bitwarden"
  "Bitwarden"
  "Backups"
  "Backup"
  "License"
  "Licenses"
  "Credentials"
)

# Path safety check. Returns 0 if path is safe to delete recursively.
is_safe_path() {
  local target="$1"
  # Reject empty
  [ -z "$target" ] && return 1
  # Reject root-ish
  [ "$target" = "/" ] && return 1
  # Resolve to absolute (do not follow final symlink; we want the link itself)
  local abs
  abs="$(cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")"
  [ -z "$abs" ] && return 1
  # Reject if equals or is parent of $HOME, /Users, etc.
  for p in "${PROTECTED_PATHS[@]}"; do
    if [ "$abs" = "$p" ]; then return 1; fi
  done
  # Reject path shorter than 4 chars or with traversal
  case "$abs" in
    *..*) return 1 ;;
  esac
  return 0
}

# Wrapper around rm -rf with safety checks and dry-run support.
safe_rm() {
  local target="$1"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if ! is_safe_path "$target"; then
    echo -e "   ${RED}⛔ Refused to delete protected path: $target${RESET}"
    log "REFUSED $target"
    return 1
  fi
  if [ "$DRY_RUN" = true ]; then
    echo -e "   ${YELLOW}🟡 would delete:${RESET} $target"
    log "DRY-RUN would-delete $target"
    return 0
  fi
  log "DELETE $target"
  rm -rf -- "$target" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
# Deep-clean accounting + generic cleaners (used by the deep steps)
# ─────────────────────────────────────────────────────────────
DEEP_LABELS=()
DEEP_VALUES=()
deep_report() { DEEP_LABELS+=("$1"); DEEP_VALUES+=("$2"); }

# Remove a whole directory/file (measuring first), then record it.
nuke_path() {
  local label="$1" path="$2"
  [ -z "$path" ] && return 0
  if [ -d "$path" ] || [ -f "$path" ] || [ -L "$path" ]; then
    local sz; sz=$(dir_size "$path")
    echo -e "   ${DIM}$label ${RESET}${DIM}($sz)${RESET}"
    if safe_rm "$path"; then
      [ "$sz" != "0B" ] && deep_report "$label" "$sz"
    fi
  fi
}

# Remove the CONTENTS of a directory but keep the directory itself.
# Use for protected parents (~/Library/Logs, DerivedData, …).
nuke_contents() {
  local label="$1" d="$2"
  [ -d "$d" ] || return 0
  local sz; sz=$(dir_size "$d")
  local had=false c
  for c in "$d"/* "$d"/.[!.]*; do
    [ -e "$c" ] || [ -L "$c" ] || continue
    safe_rm "$c" && had=true
  done
  if [ "$had" = true ] && [ -n "$sz" ] && [ "$sz" != "0B" ]; then
    echo -e "   ${DIM}$label ${RESET}${DIM}($sz)${RESET}"
    deep_report "$label" "$sz"
  fi
}

# Run a native cleanup command, honoring dry-run + logging.
run_clean_cmd() {
  local label="$1"; shift
  if ! command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    echo -e "   ${YELLOW}🟡 would run:${RESET} $*"
    log "DRY-RUN would-run: $*"
    deep_report "$label" "dry-run"
    return 0
  fi
  log "RUN $*"
  if spinner_run "$label..." "$@"; then
    printf "   ${GREEN}✅${RESET} %s\n" "$label"
    deep_report "$label" "cleaned"
  else
    printf "   ${YELLOW}⚠️${RESET}  %s ${DIM}(skipped)${RESET}\n" "$label"
    deep_report "$label" "skipped"
    log "cmd failed: $*"
  fi
}

# Confirm helper that respects --yes. Arrow-driven, defaults to No.
confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = true ]; then return 0; fi
  # Strip the old "(y/n): " tail — the picker shows the choices itself.
  prompt="${prompt%% (y/n)*}"
  prompt="${prompt%%: }"
  menu_yesno "$prompt  ${DIM}←/→ then Enter${RESET}"
}

# Validate that a folder looks like a real project we can clean.
is_project_dir() {
  local d="$1"
  [ -d "$d" ] || return 1
  for marker in package.json android/build.gradle android/settings.gradle ios/Podfile pubspec.yaml Cargo.toml; do
    [ -e "$d/$marker" ] && return 0
  done
  return 1
}

# Stop any running Gradle daemons so a later cache wipe is safe.
stop_gradle_daemons() {
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f "GradleDaemon" >/dev/null 2>&1; then
      echo -e "   ${DIM}stopping running Gradle daemons...${RESET}"
      log "stopping gradle daemons"
      pkill -f "GradleDaemon" 2>/dev/null
      sleep 1
    fi
  fi
  if command -v gradle >/dev/null 2>&1; then
    gradle --stop >/dev/null 2>&1 || true
  fi
}

# Warn (but don't block) if Android Studio / Xcode are running.
warn_running_ides() {
  local running=()
  pgrep -x "Android Studio" >/dev/null 2>&1 && running+=("Android Studio")
  pgrep -x "Xcode" >/dev/null 2>&1 && running+=("Xcode")
  if [ ${#running[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠️  These apps are running and may hold locks: ${running[*]}${RESET}"
    echo -e "${DIM}   Consider quitting them before continuing for best results.${RESET}"
  fi
}

# ─────────────────────────────────────────────────────────────
# DEEP CLEANERS — global dev-tool & system caches
# Each prints what it does and records freed sizes via deep_report.
# ─────────────────────────────────────────────────────────────

# Gradle: remove dependency caches AND the big version-numbered cache
# dirs (~/.gradle/caches/9.3.1, 8.14.3, …) which are the real space hogs.
# Preserve: wrapper (Gradle distribution), init.d, gradle.properties.
clean_gradle() {
  if [ ! -d "$HOME/.gradle" ]; then
    echo -e "   ${DIM}~/.gradle not found, skipping${RESET}"
    return 0
  fi
  local before; before=$(du -sk "$HOME/.gradle/caches" 2>/dev/null | awk '{print $1}')
  before=${before:-0}
  # Version dirs (e.g. 9.3.1, 8.14.3) + classic dependency/build caches.
  local sub d
  for sub in 'caches/[0-9]*' 'caches/modules-2' 'caches/transforms-*' \
             'caches/build-cache-*' 'caches/jars-*' 'caches/journal-*' \
             'caches/kotlin-dsl' 'caches/8.*' 'caches/9.*' 'daemon' 'workers'; do
    for d in "$HOME/.gradle"/$sub; do
      [ -e "$d" ] || continue
      safe_rm "$d"
    done
  done
  if [ "$before" -gt 0 ]; then
    local mb; mb=$(echo "scale=1; $before/1024" | bc)
    local human="${mb} MB"
    [ "${before}" -gt 1048576 ] && human="$(echo "scale=2; $before/1048576" | bc) GB"
    echo -e "   ${GREEN}✅ Freed ~$human${RESET} ${DIM}(version + dependency caches)${RESET}"
    deep_report "Gradle caches" "$human"
  else
    echo -e "   ${DIM}Nothing to clean${RESET}"
  fi
  echo -e "   ${DIM}Preserved: ~/.gradle/wrapper, init.d, gradle.properties${RESET}"
}

# JS / native package-manager global caches.
clean_pkg_caches() {
  # npm — _cacache is frequently 5–15 GB
  if command -v npm >/dev/null 2>&1; then
    run_clean_cmd "npm cache" npm cache clean --force
  fi
  nuke_path "npm _cacache"   "$HOME/.npm/_cacache"
  nuke_path "npm _npx"       "$HOME/.npm/_npx"
  nuke_path "npm _logs"      "$HOME/.npm/_logs"
  # yarn
  if command -v yarn >/dev/null 2>&1; then
    run_clean_cmd "yarn cache" yarn cache clean
  fi
  nuke_path "Yarn cache"     "$HOME/Library/Caches/Yarn"
  nuke_path "Yarn berry cache" "$HOME/.yarn/berry/cache"
  # pnpm
  if command -v pnpm >/dev/null 2>&1; then
    run_clean_cmd "pnpm store" pnpm store prune
  fi
  nuke_path "pnpm store"     "$HOME/Library/pnpm/store"
  nuke_path "pnpm store(alt)" "$HOME/.pnpm-store"
  # bun
  nuke_path "bun cache"      "$HOME/.bun/install/cache"
  # CocoaPods
  if command -v pod >/dev/null 2>&1 && [ "$DRY_RUN" = false ]; then
    run_clean_cmd "CocoaPods cache" pod cache clean --all
  fi
  nuke_path "CocoaPods cache" "$HOME/Library/Caches/CocoaPods"
  nuke_path "Carthage cache" "$HOME/Library/Caches/org.carthage.CarthageKit"
  # Python pip
  nuke_path "pip cache"      "$HOME/Library/Caches/pip"
  # Python uv — often 20–60 GB
  if command -v uv >/dev/null 2>&1 && [ "$DRY_RUN" = false ]; then
    # claude-mem's chroma-mcp (run via uvx) holds the uv cache lock for its
    # whole lifetime, so `uv cache clean` would wait on it forever.
    if pgrep -f "chroma-mcp" >/dev/null 2>&1; then
      echo -e "   ${DIM}stopping chroma-mcp (holds uv cache lock)...${RESET}"
      log "stopping chroma-mcp"
      pkill -f "chroma-mcp" 2>/dev/null
      sleep 1
    fi
    run_clean_cmd "uv cache" uv cache clean
  fi
  nuke_path "uv cache"       "$HOME/.cache/uv"
  # SwiftPM
  nuke_path "SwiftPM cache"  "$HOME/Library/Caches/org.swift.swiftpm"
  nuke_path "SwiftPM clones" "$HOME/Library/org.swift.swiftpm"
  # Aggressive-only: module caches that re-download a lot
  if [ "$AGGRESSIVE" = true ]; then
    run_clean_cmd "Go build/mod cache" go clean -cache -modcache -fuzzcache
    nuke_path "Cargo registry cache" "$HOME/.cargo/registry/cache"
    nuke_path "Cargo registry src"   "$HOME/.cargo/registry/src"
  fi
}

# Homebrew downloads + outdated versions.
clean_brew() {
  command -v brew >/dev/null 2>&1 || return 0
  if [ "$AGGRESSIVE" = true ]; then
    run_clean_cmd "Homebrew cleanup (prune=all)" brew cleanup -s --prune=all
  else
    run_clean_cmd "Homebrew cleanup" brew cleanup -s
  fi
  nuke_path "Homebrew downloads" "$(brew --cache 2>/dev/null)"
}

# Docker: build cache + unused images (huge). Volumes only with -a.
clean_docker() {
  [ "$SKIP_DOCKER" = true ] && return 0
  command -v docker >/dev/null 2>&1 || return 0
  if ! docker info >/dev/null 2>&1; then
    echo -e "   ${DIM}Docker not running, skipping${RESET}"
    return 0
  fi
  run_clean_cmd "Docker build cache" docker builder prune -af
  run_clean_cmd "Docker unused images/containers/nets" docker system prune -af
  if [ "$AGGRESSIVE" = true ] && [ "${KEEP_DOCKER_VOLUMES:-false}" = false ]; then
    run_clean_cmd "Docker volumes" docker volume prune -af
  fi
}

# Xcode / simulators beyond DerivedData.
clean_xcode_deep() {
  local plat
  for plat in "iOS DeviceSupport" "watchOS DeviceSupport" "tvOS DeviceSupport" "xrOS DeviceSupport"; do
    nuke_contents "Xcode $plat" "$HOME/Library/Developer/Xcode/$plat"
  done
  nuke_path "CoreSimulator caches" "$HOME/Library/Developer/CoreSimulator/Caches"
  nuke_contents "Xcode iOS device logs" "$HOME/Library/Developer/Xcode/iOS Device Logs"
  if command -v xcrun >/dev/null 2>&1; then
    run_clean_cmd "Remove unavailable simulators" xcrun simctl delete unavailable
  fi
  if [ "$AGGRESSIVE" = true ]; then
    nuke_contents "Xcode Archives" "$HOME/Library/Developer/Xcode/Archives"
    clean_simulator_devices
  fi
}

# Delete non-booted simulator devices (~/Library/Developer/CoreSimulator/Devices).
# These are trivially recreated by Xcode but hold per-device app data, so this
# only runs with --aggressive. Booted devices are always skipped.
clean_simulator_devices() {
  command -v xcrun >/dev/null 2>&1 || return 0
  local dev_dir="$HOME/Library/Developer/CoreSimulator/Devices"
  [ -d "$dev_dir" ] || return 0

  local booted=()
  while IFS= read -r udid; do
    [ -n "$udid" ] && booted+=("$udid")
  done < <(xcrun simctl list devices booted -j 2>/dev/null | grep -o '"udid" *: *"[^"]*"' | cut -d'"' -f4)

  local total_kb=0 removed=0 d udid sz is_booted b
  for d in "$dev_dir"/*/; do
    [ -d "$d" ] || continue
    udid="$(basename "$d")"
    is_booted=false
    for b in "${booted[@]}"; do
      [ "$b" = "$udid" ] && is_booted=true && break
    done
    [ "$is_booted" = true ] && continue

    sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    total_kb=$((total_kb + ${sz:-0}))
    if [ "$DRY_RUN" = true ]; then
      echo -e "   ${YELLOW}🟡 would delete sim device:${RESET} $udid ($(dir_size "$d"))"
    else
      xcrun simctl delete "$udid" >/dev/null 2>&1 && removed=$((removed + 1))
    fi
  done

  if [ "$total_kb" -gt 0 ]; then
    local mb human
    mb=$(echo "scale=1; $total_kb/1024" | bc)
    human="${mb} MB"
    [ "$total_kb" -gt 1048576 ] && human="$(echo "scale=2; $total_kb/1048576" | bc) GB"
    if [ "$DRY_RUN" = true ]; then
      deep_report "Simulator devices" "would free ~$human"
    else
      echo -e "   ${GREEN}✅ Removed $removed simulator device(s), freed ~$human${RESET}"
      deep_report "Simulator devices" "$human"
    fi
  else
    echo -e "   ${DIM}No unused simulator devices found${RESET}"
  fi
}

# Android SDK / Studio + JetBrains caches.
clean_android_studio() {
  nuke_path "Android build-cache" "$HOME/.android/build-cache"
  nuke_path "Android cache"       "$HOME/.android/cache"
  local d
  for d in "$HOME/Library/Caches/Google"/AndroidStudio*; do
    [ -e "$d" ] || continue
    nuke_path "Android Studio cache ($(basename "$d"))" "$d"
  done
  nuke_path "JetBrains caches" "$HOME/Library/Caches/JetBrains"
  for d in "$HOME"/*.hprof; do
    [ -e "$d" ] || continue
    nuke_path "Java heap dump ($(basename "$d"))" "$d"
  done
}

# Editor caches (VS Code / Cursor) — caches only, never settings/extensions.
clean_editor_caches() {
  local app base sub
  for app in "Code" "Code - Insiders" "Cursor"; do
    base="$HOME/Library/Application Support/$app"
    [ -d "$base" ] || continue
    for sub in "Cache" "CachedData" "Code Cache" "GPUCache" "DawnGraphiteCache" "DawnWebGPUCache" "logs"; do
      nuke_path "$app/$sub" "$base/$sub"
    done
  done
  nuke_path "VS Code ShipIt" "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt"
}

# Logs, crash/diagnostic reports, QuickLook thumbnails.
clean_logs_misc() {
  nuke_contents "User logs"          "$HOME/Library/Logs"
  nuke_contents "Crash diagnostics"  "$HOME/Library/Logs/DiagnosticReports"
  nuke_contents "CrashReporter"      "$HOME/Library/Application Support/CrashReporter"
  if command -v qlmanage >/dev/null 2>&1; then
    run_clean_cmd "QuickLook thumbnail cache" qlmanage -r cache
  fi
}

# macOS Media Analysis + ~/Library/Caches with protections.
clean_macos_caches() {
  local MEDIA_DIR="$HOME/Library/Containers/com.apple.mediaanalysisd/Data"
  local CACHES_DIR="$HOME/Library/Caches"

  if [ -d "$MEDIA_DIR" ]; then
    nuke_path "Media Analysis cache" "$MEDIA_DIR"
  fi

  if [ -d "$CACHES_DIR" ]; then
    local size_before; size_before=$(dir_size "$CACHES_DIR")
    local protected_n=0 locked_n=0 item base prefix protected
    for item in "$CACHES_DIR"/*; do
      [ -e "$item" ] || continue
      base="$(basename "$item")"
      protected=false
      for prefix in "${PROTECTED_CACHE_PREFIXES[@]}"; do
        case "$base" in
          "$prefix"|"$prefix".*|"$prefix"-*) protected=true; break ;;
        esac
      done
      if [ "$protected" = true ]; then
        protected_n=$((protected_n + 1))
        continue
      fi
      if ! safe_rm "$item"; then
        locked_n=$((locked_n + 1))
      fi
    done
    echo -e "   ${GREEN}✅ ~/Library/Caches cleaned${RESET} ${DIM}($size_before total; $protected_n protected, $locked_n locked)${RESET}"
    deep_report "~/Library/Caches" "$size_before ($protected_n protected)"
  fi
}

# Empty Trash (contents only), including mounted-volume trashes.
clean_trash() {
  local d
  if [ -d "$HOME/.Trash" ]; then
    local sz; sz=$(dir_size "$HOME/.Trash")
    for d in "$HOME/.Trash"/* "$HOME/.Trash"/.[!.]*; do
      [ -e "$d" ] || [ -L "$d" ] || continue
      safe_rm "$d"
    done
    [ -n "$sz" ] && [ "$sz" != "0B" ] && deep_report "Trash" "$sz"
    echo -e "   ${GREEN}✅ Trash emptied${RESET} ${DIM}($sz)${RESET}"
  fi
}

# Watchman + Metro / React Native temp caches.
clean_rn_temp() {
  if command -v watchman >/dev/null 2>&1 && [ "$DRY_RUN" = false ]; then
    watchman watch-del-all >/dev/null 2>&1 || true
  fi
  local rn_tmp RN_TMP="${TMPDIR:-/tmp/}"
  for rn_tmp in "$RN_TMP"react-* "$RN_TMP"metro-* "$RN_TMP"haste-map-*; do
    [ -e "$rn_tmp" ] || continue
    safe_rm "$rn_tmp"
  done
  echo -e "   ${GREEN}✅ Watchman / Metro temp cleared${RESET}"
}


# ── "Clean everything" extras (mode 6) ───────────────────────
# Oldest supported RN = 0.65. Keep only NDK / build-tools versions some
# RN >= 0.65 default template uses; everything else is dead weight.
KEEP_NDK=("21.4.7075529" "23.1.7779620" "25.1.8937393" "26.1.10909125" "27.1.12297006")
KEEP_BUILD_TOOLS=("30.0.2" "31.0.0" "33.0.0" "34.0.0")   # + anything >= 35
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"

in_list() { local x="$1"; shift; local i; for i in "$@"; do [ "$i" = "$x" ] && return 0; done; return 1; }

clean_android_sdk_old() {
  [ -d "$ANDROID_SDK" ] || { echo -e "   ${DIM}Android SDK not found, skipping${RESET}"; return 0; }
  local d v major
  for d in "$ANDROID_SDK/ndk"/*; do
    [ -d "$d" ] || continue; v="$(basename "$d")"
    major="${v%%.*}"
    in_list "$v" "${KEEP_NDK[@]}" && continue
    [ "$major" -ge 28 ] 2>/dev/null && continue
    nuke_path "NDK $v (unused by RN >= 0.65)" "$d"
  done
  nuke_path "NDK legacy ndk-bundle" "$ANDROID_SDK/ndk-bundle"
  for d in "$ANDROID_SDK/build-tools"/*; do
    [ -d "$d" ] || continue; v="$(basename "$d")"
    major="${v%%.*}"
    case "$v" in *-rc*) nuke_path "build-tools $v (release candidate)" "$d"; continue ;; esac
    in_list "$v" "${KEEP_BUILD_TOOLS[@]}" && continue
    [ "$major" -ge 35 ] 2>/dev/null && continue
    nuke_path "build-tools $v (unused by RN >= 0.65)" "$d"
  done
  for d in "$ANDROID_SDK/platforms"/android-*; do
    [ -d "$d" ] || continue; v="${d##*android-}"
    [ "${v%%.*}" -lt 30 ] 2>/dev/null && nuke_path "platform android-$v (< API 30)" "$d"
  done
  nuke_path "SDK sources (IDE source browsing only)" "$ANDROID_SDK/sources"
}

clean_android_emulator() {
  pgrep -f qemu-system >/dev/null 2>&1 && { echo -e "   ${YELLOW}Emulator running, skipping${RESET}"; return 0; }
  nuke_path "Android emulator binary"     "$ANDROID_SDK/emulator"
  nuke_path "Android system images"       "$ANDROID_SDK/system-images"
  nuke_path "Android skins"               "$ANDROID_SDK/skins"
  nuke_path "Android AVDs (~/.android/avd)" "$HOME/.android/avd"
}

clean_ios_simulators_all() {
  command -v xcrun >/dev/null 2>&1 || return 0
  if [ "$DRY_RUN" = true ]; then
    echo -e "   ${YELLOW}🟡 would delete:${RESET} all simulator devices + runtimes ($(dir_size "$HOME/Library/Developer/CoreSimulator"))"
    return 0
  fi
  xcrun simctl shutdown all >/dev/null 2>&1
  run_clean_cmd "All iOS simulator devices" xcrun simctl delete all
  run_clean_cmd "All iOS simulator runtimes" xcrun simctl runtime delete all
  nuke_path "CoreSimulator caches" "$HOME/Library/Developer/CoreSimulator/Caches"
  nuke_path "Xcode Previews" "$HOME/Library/Developer/Xcode/UserData/Previews"
}

# ─────────────────────────────────────────────────────────────
# Orphaned app data (mode 5)
#
# macOS "uninstall" = drag the .app to the Trash. Everything the app
# wrote into ~/Library stays behind forever. This scanner builds an
# inventory of every app LaunchServices knows about, then reports the
# ~/Library leftovers that belong to no installed app. Nothing is
# deleted without an explicit per-item confirmation.
# ─────────────────────────────────────────────────────────────

ORPHAN_LABELS=()
ORPHAN_PATHS=()
ORPHAN_SIZES=()
ORPHAN_KB=()
ORPHAN_KINDS=()

# Ignore leftovers smaller than this (KB). Stale 4 KB plists are noise;
# the point of this mode is reclaiming real space. LaunchAgents are
# always reported regardless of size — an orphan agent still runs.
ORPHAN_MIN_KB=${ORPHAN_MIN_KB:-1024}

# Folder/file names that never map to a .app but are still in use:
# CLI tools, language runtimes, system services, sync clients.
ORPHAN_WHITELIST=(
  # Apple / system services
  com.apple AddressBook Accounts AppStore AquaTerm Assistant Autosave\ Information
  CallHistoryDB CallHistoryTransactions CloudDocs ClassKit CrashReporter
  FaceTime FileProvider Fonts Group\ Containers Icons Knowledge MobileSync
  Notes SyncServices Safari Screen\ Time SharedFileList Sharing Spotlight
  Suggestions com.apple.TCC iCloud icdd Keychains Mail Messages
  # Shells / dotfile-ish
  zsh bash fish nano vim neovim tmux git gh op
  # Language + package managers (CLI, no .app)
  node npm npmrc nvm fnm pnpm yarn bun deno pip pip3 pipx pyenv poetry uv
  Homebrew brew rbenv rvm gem bundler cargo rustup go golang java jenv sdkman
  composer php ruby python python3 dotnet nuget maven gradle Gradle
  cocoapods CocoaPods pod fastlane watchman flutter dart
  # Cloud / infra CLIs
  gcloud google-cloud-sdk aws awscli azure kubectl helm terraform doctl
  vercel netlify firebase supabase heroku railway fly flyctl ngrok
  # Dev tooling data dirs
  claude claude-code .claude JetBrains Code Cursor Windsurf codeium
  vscode vscode-insiders Codeium Continue ollama lmstudio
  # Misc real-but-headless
  Adobe Microsoft AddressBookSourceSync ByHost Caches Containers Logs
  Preferences Application\ Support CloudKit Trial Keybase
)

# Return 0 if $1 is whitelisted (exact match, or an apple/reverse-dns prefix).
orphan_is_whitelisted() {
  local n="$1" w
  local nl; nl=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')
  case "$nl" in
    *apple*|.*|*.lockfile|*.sock) return 0 ;;
    group.*|systemgroup.*) return 0 ;;
  esac
  for w in "${ORPHAN_WHITELIST[@]}"; do
    [ "$nl" = "$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')" ] && return 0
  done
  # A command with this name on PATH means something still uses the dir.
  command -v "$n" >/dev/null 2>&1 && return 0
  return 1
}

# Normalize a name for fuzzy comparison: lowercase, strip non-alphanumerics.
orphan_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

# Build the installed-app inventory into two temp files:
#   $ORPHAN_IDS   — one bundle identifier per line (lowercased)
#   $ORPHAN_NAMES — one normalized app name per line
orphan_build_inventory() {
  ORPHAN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/clean-orphan.XXXXXX") || return 1
  ORPHAN_IDS="$ORPHAN_TMP/ids"
  ORPHAN_NAMES="$ORPHAN_TMP/names"
  : > "$ORPHAN_IDS"
  : > "$ORPHAN_NAMES"

  local lsr="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$lsr" ]; then
    "$lsr" -dump 2>/dev/null \
      | sed -n 's/^[[:space:]]*identifier:[[:space:]]*//p' \
      | tr '[:upper:]' '[:lower:]' | sort -u >> "$ORPHAN_IDS"
    "$lsr" -dump 2>/dev/null \
      | sed -n 's/^[[:space:]]*path:[[:space:]]*//p' \
      | sed 's/ (0x[0-9a-f]*)$//' | grep '\.app$' \
      | sed 's|.*/||; s|\.app$||' >> "$ORPHAN_TMP/rawnames"
  fi

  # Directly present bundles (covers apps LaunchServices has not indexed).
  local d a
  for d in /Applications /Applications/Utilities "$HOME/Applications" \
           /System/Applications /System/Applications/Utilities; do
    [ -d "$d" ] || continue
    for a in "$d"/*.app; do
      [ -d "$a" ] || continue
      basename "$a" .app >> "$ORPHAN_TMP/rawnames"
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$a/Contents/Info.plist" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' >> "$ORPHAN_IDS"
    done
  done

  # macOS ships thousands of headless services whose ~/Library data looks
  # ownerless: private frameworks, launchd daemons, /usr/libexec helpers.
  # Learn their names so they are never reported.
  {
    ls /System/Library/PrivateFrameworks /System/Library/Frameworks 2>/dev/null \
      | sed 's/\.framework$//'
    ls /usr/libexec /usr/sbin /usr/bin /sbin /bin 2>/dev/null
    ls /System/Library/CoreServices 2>/dev/null | sed 's/\.app$//'
    ls /System/Library/LaunchAgents /System/Library/LaunchDaemons 2>/dev/null \
      | sed 's/\.plist$//'
    # Every bundle/executable LaunchServices knows about, not just .app —
    # appex, xpc and plugin names show up as ~/Library data owners too.
    if [ -x "$lsr" ]; then
      "$lsr" -dump 2>/dev/null \
        | sed -n 's/^[[:space:]]*path:[[:space:]]*//p' \
        | sed 's/ (0x[0-9a-f]*)$//; s|.*/||; s|\.[A-Za-z]*$||'
      "$lsr" -dump 2>/dev/null \
        | sed -n 's/^[[:space:]]*name:[[:space:]]*//p'
      # Apple service ids appear all over the dump (sandbox rules, mach
      # names, URL claims). Their last component is often exactly what an
      # Apple daemon names its ~/Library folder (familycircled, Animoji).
      "$lsr" -dump 2>/dev/null \
        | grep -oE 'com\.apple\.[A-Za-z0-9._-]+' \
        | awk -F. '{print $NF}'
    fi
  } > "$ORPHAN_TMP/rawsys" 2>/dev/null

  local sysn
  while IFS= read -r sysn; do
    [ -n "$sysn" ] || continue
    { orphan_norm "$sysn"; echo; } >> "$ORPHAN_TMP/sysnames"
  done < <(sort -u "$ORPHAN_TMP/rawsys" 2>/dev/null)
  [ -f "$ORPHAN_TMP/sysnames" ] && sort -u -o "$ORPHAN_TMP/sysnames" "$ORPHAN_TMP/sysnames"

  # Login items / agents still referenced by launchd count as "installed".
  for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
    [ -d "$d" ] || continue
    for a in "$d"/*.plist; do
      [ -f "$a" ] || continue
      basename "$a" .plist | tr '[:upper:]' '[:lower:]' >> "$ORPHAN_TMP/agentids"
    done
  done

  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    { orphan_norm "$n"; echo; } >> "$ORPHAN_NAMES"
  done < <(sort -u "$ORPHAN_TMP/rawnames" 2>/dev/null)

  sort -u -o "$ORPHAN_IDS" "$ORPHAN_IDS"
  sort -u -o "$ORPHAN_NAMES" "$ORPHAN_NAMES"
  [ -s "$ORPHAN_IDS" ]
}

# Return 0 if the entry name belongs to an installed app.
orphan_has_owner() {
  local name="$1"
  local nl; nl=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

  # Strip trailing suffixes macOS appends to data dirs.
  nl="${nl%.plist}"
  nl="${nl%.savedstate}"
  nl="${nl%.binarycookies}"

  # Reverse-DNS style name → match against bundle identifiers, in both
  # directions so helpers (com.foo.bar.helper) and umbrella ids match.
  case "$nl" in
    *.*)
      grep -qxF "$nl" "$ORPHAN_IDS" && return 0
      grep -q "^${nl}\." "$ORPHAN_IDS" && return 0
      local parent="${nl%.*}"
      while [ -n "$parent" ]; do
        grep -qxF "$parent" "$ORPHAN_IDS" && return 0
        case "$parent" in *.*) parent="${parent%.*}" ;; *) break ;; esac
      done
      # Vendor-prefix match: com.acme.* installed means com.acme.thing is owned.
      local vendor; vendor=$(printf '%s' "$nl" | cut -d. -f1-2)
      grep -q "^${vendor}\." "$ORPHAN_IDS" && return 0
      ;;
  esac

  # Plain name → compare normalized against installed app names, and
  # against the trailing component of every bundle identifier.
  local norm; norm=$(orphan_norm "$name")
  [ ${#norm} -lt 3 ] && return 0   # too short to judge; keep it
  grep -qxF "$norm" "$ORPHAN_NAMES" && return 0
  if [ ${#norm} -ge 5 ]; then
    grep -q "$norm" "$ORPHAN_NAMES" && return 0
    grep -q "\.${norm}$" "$ORPHAN_IDS" && return 0
  fi
  [ -f "$ORPHAN_TMP/agentids" ] && grep -q "$norm" "$ORPHAN_TMP/agentids" && return 0
  [ -f "$ORPHAN_TMP/sysnames" ] && grep -qxF "$norm" "$ORPHAN_TMP/sysnames" && return 0
  return 1
}

# Format a KB count as a human size, so each entry is measured only once.
orphan_human_kb() {
  awk -v k="$1" 'BEGIN{
    if (k >= 1048576) printf "%.1fG", k/1048576;
    else if (k >= 1024) printf "%.0fM", k/1024;
    else printf "%dK", k;
  }'
}

# Scan one directory's immediate children for orphans.
# $1 = human label, $2 = directory
orphan_scan_dir() {
  local label="$1" dir="$2" e base
  [ -d "$dir" ] || return 0
  local kb
  for e in "$dir"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    base=$(basename "$e")
    orphan_is_whitelisted "$base" && continue
    orphan_has_owner "$base" && continue
    kb=$(du -sk "$e" 2>/dev/null | awk '{print $1}')
    [ -z "$kb" ] && kb=0
    if [ "$label" != "LaunchAgents" ] && [ "$kb" -lt "$ORPHAN_MIN_KB" ]; then
      ORPHAN_SKIPPED_SMALL=$((ORPHAN_SKIPPED_SMALL + 1))
      continue
    fi
    ORPHAN_LABELS+=("$base")
    ORPHAN_PATHS+=("$e")
    ORPHAN_SIZES+=("$(orphan_human_kb "$kb")")
    ORPHAN_KB+=("$kb")
    ORPHAN_KINDS+=("$label")
  done
}

# ─────────────────────────────────────────────────────────────
# Unused images — the former cleanimgs.sh, embedded verbatim.
#
# It is kept as a payload rather than inlined so this stays a single
# file: written to a temp script and run inside the chosen project,
# because it keys its config on $PWD and scans the tree it runs in.
# ─────────────────────────────────────────────────────────────
imgs_payload() {
  cat <<'CLEANIMGS_PAYLOAD_EOF'
# Unused Images Cleaner
# Scan codebase for images never referenced, print colored report,
# optionally delete unused files on confirmation.

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; MAGENTA="$(tput setaf 5)"; CYAN="$(tput setaf 6)"; GRAY="$(tput setaf 8)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; GRAY=""
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────
hr() { printf "${GRAY}%s${RESET}\n" "────────────────────────────────────────────────────────────────────────────"; }
title() { printf "\n${BOLD}${CYAN}▎%s${RESET}\n" "$1"; }
ok() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}⚠${RESET} %s\n" "$1"; }
err() { printf "${RED}✗${RESET} %s\n" "$1" >&2; }
ask() { local p="$1"; printf "${BOLD}${MAGENTA}?${RESET} ${BOLD}%s${RESET} " "$p"; }

human_size() {
  local b="$1"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB",u," ");
    i=1; while (b>=1024 && i<5) { b=b/1024; i++ }
    if (i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
  }'
}

# ─── Banner ──────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
printf "\n"
printf "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}${BLUE}║${RESET}  ${BOLD}🖼️   UNUSED IMAGES CLEANER${RESET}                                             ${BOLD}${BLUE}║${RESET}\n"
printf "${BOLD}${BLUE}║${RESET}  ${DIM}Scan codebase for images never referenced${RESET}                              ${BOLD}${BLUE}║${RESET}\n"
printf "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════════════╝${RESET}\n\n"

# ─── Config + first-run install ──────────────────────────────────────────────
# Per-project config: key on current working directory so each project
# keeps its own saved paths instead of clobbering a single global file.
CONFIG_DIR="$HOME/.cleanimgs"
mkdir -p "$CONFIG_DIR"
CONFIG_KEY="$(printf '%s' "$PWD" | shasum | cut -d' ' -f1)"
CONFIG_FILE="$CONFIG_DIR/$CONFIG_KEY"

# Flag: `--reset` wipes saved config to re-prompt
if [[ "${1:-}" == "--reset" ]]; then
  [[ -f "$CONFIG_FILE" ]] && rm -f "$CONFIG_FILE"
  ok "Config reset. Will re-prompt for paths."
  printf "\n"
fi

# Discover folders inside SEARCH_ROOT that hold images.
# Strategy: any dir under SEARCH_ROOT (skipping build/junk) containing ≥3 image files.
# Boosted ranking for typical names (img/imgs/images/assets/icons/media/pictures/photos).
discover_image_dirs() {
  local root="$1"
  local tmp
  tmp="$(mktemp)"

  # Find image files, get their parent dirs, count per dir.
  find "$root" \
    \( -type d \( -name node_modules -o -name .git -o -name Pods -o -name build -o -name .gradle -o -name ios -o -name android -o -name .next -o -name dist -o -name .expo \) -prune \) \
    -o -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.svg' -o -iname '*.bmp' -o -iname '*.heic' -o -iname '*.avif' \) -print 2>/dev/null \
    | while IFS= read -r f; do dirname "$f"; done \
    | sort | uniq -c | awk '$1 >= 3 {sub(/^ *[0-9]+ /,"",$0); count=$0; getline_line=$0}' \
    > /dev/null 2>&1 || true

  # Cleaner pipe: count + path
  find "$root" \
    \( -type d \( -name node_modules -o -name .git -o -name Pods -o -name build -o -name .gradle -o -name ios -o -name android -o -name .next -o -name dist -o -name .expo \) -prune \) \
    -o -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.svg' -o -iname '*.bmp' -o -iname '*.heic' -o -iname '*.avif' \) -print 2>/dev/null \
    | sed 's|/[^/]*$||' \
    | sort | uniq -c \
    | awk '$1 >= 3' \
    | sort -k2 \
    > "$tmp"

  # Rank: preferred basenames first, then by count desc
  awk -v root="$root" '
    {
      count=$1
      $1=""
      sub(/^ +/,"",$0)
      path=$0
      n=split(path,parts,"/")
      base=tolower(parts[n])
      score=0
      if (base ~ /^(images|imgs|img|icons|assets|media|pictures|photos|graphics|illustrations)$/) score=100
      else if (base ~ /(images|imgs|img|icons|assets|media|pictures|photos)/) score=50
      printf "%d\t%d\t%s\n", score, count, path
    }
  ' "$tmp" | sort -k1,1nr -k2,2nr -k3,3 > "${tmp}.ranked"

  cat "${tmp}.ranked"
  rm -f "$tmp" "${tmp}.ranked"
}

prompt_paths() {
  ask "Search root ${DIM}(Enter = $PWD)${RESET}:"
  read -r SEARCH_ROOT < /dev/tty
  SEARCH_ROOT="${SEARCH_ROOT:-$PWD}"
  SEARCH_ROOT="${SEARCH_ROOT/#\~/$HOME}"
  SEARCH_ROOT="${SEARCH_ROOT%/}"
  [[ -d "$SEARCH_ROOT" ]] || { err "Not a directory: $SEARCH_ROOT"; exit 1; }

  printf "\n${DIM}Scanning for image folders in${RESET} %s ${DIM}...${RESET}\n" "$SEARCH_ROOT"

  local found
  found="$(discover_image_dirs "$SEARCH_ROOT")"

  if [[ -z "$found" ]]; then
    warn "No image folders auto-detected. Paste path manually."
    ask "Images folder path:"
    read -r IMG_DIR < /dev/tty
    IMG_DIR="${IMG_DIR/#\~/$HOME}"
    IMG_DIR="${IMG_DIR%/}"
    [[ -d "$IMG_DIR" ]] || { err "Not a directory: $IMG_DIR"; exit 1; }
    return
  fi

  local -a paths counts
  local i=0
  while IFS=$'\t' read -r score cnt path; do
    paths[i]="$path"
    counts[i]="$cnt"
    i=$((i + 1))
  done <<< "$found"

  title "📂 Candidate image folders"
  printf "\n"
  for ((j=0; j<i; j++)); do
    local rel="${paths[j]#$SEARCH_ROOT/}"
    printf "  ${BOLD}%2d)${RESET} ${CYAN}%s${RESET}  ${DIM}(%s images)${RESET}\n" \
      "$((j + 1))" "$rel" "${counts[j]}"
  done
  printf "  ${BOLD}%2s)${RESET} ${DIM}Type custom path${RESET}\n" "0"
  printf "\n"

  local CHOICE
  while true; do
    ask "Pick folder [0-$i]:"
    read -r CHOICE < /dev/tty
    if [[ "$CHOICE" == "0" ]]; then
      ask "Images folder path:"
      read -r IMG_DIR < /dev/tty
      IMG_DIR="${IMG_DIR/#\~/$HOME}"
      IMG_DIR="${IMG_DIR%/}"
      [[ -d "$IMG_DIR" ]] || { err "Not a directory: $IMG_DIR"; exit 1; }
      break
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= i )); then
      IMG_DIR="${paths[$((CHOICE - 1))]}"
      break
    else
      err "Invalid. Enter 0–$i."
    fi
  done
}



if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  if [[ ! -d "${IMG_DIR:-}" || ! -d "${SEARCH_ROOT:-}" ]]; then
    warn "Saved paths no longer valid. Re-prompting."
    rm -f "$CONFIG_FILE"
    prompt_paths
    printf 'IMG_DIR=%q\nSEARCH_ROOT=%q\n' "$IMG_DIR" "$SEARCH_ROOT" > "$CONFIG_FILE"
  else
    ok "Loaded saved paths ${DIM}(run with ${CYAN}--reset${DIM} to change)${RESET}"
  fi
else
  title "👋 First time setup"
  printf "\n"
  prompt_paths
  printf 'IMG_DIR=%q\nSEARCH_ROOT=%q\n' "$IMG_DIR" "$SEARCH_ROOT" > "$CONFIG_FILE"
  ok "Saved. Won't ask again."
  printf "\n"
fi

if command -v rg >/dev/null 2>&1; then
  SEARCHER="rg"
  ok "Using ${BOLD}ripgrep${RESET}"
else
  SEARCHER="grep"
  warn "ripgrep not found, using ${BOLD}grep${RESET} (slower). Install: ${CYAN}brew install ripgrep${RESET}"
fi

printf "\n${DIM}Images:${RESET} %s\n" "$IMG_DIR"
printf "${DIM}Root:  ${RESET} %s\n" "$SEARCH_ROOT"
hr

# ─── Setup ───────────────────────────────────────────────────────────────────
TMP_USED="$(mktemp)"
TMP_UNUSED="$(mktemp)"
TMP_UNUSED_PATHS="$(mktemp)"
trap 'rm -f "$TMP_USED" "$TMP_UNUSED" "$TMP_UNUSED_PATHS"' EXIT

RG_GLOBS=(
  "--glob=!node_modules"
  "--glob=!ios/Pods"
  "--glob=!ios/build"
  "--glob=!android/build"
  "--glob=!android/app/build"
  "--glob=!android/.gradle"
  "--glob=!.git"
  "--glob=!*.lock"
  "--glob=!package-lock.json"
  "--glob=!yarn.lock"
)
case "$IMG_DIR" in
  "$SEARCH_ROOT"/*)
    REL="${IMG_DIR#$SEARCH_ROOT/}"
    RG_GLOBS+=("--glob=!$REL/**")
    ;;
esac

EXTS_REGEX='\.(png|jpg|jpeg|gif|webp|svg|bmp|heic|avif)$'

IMG_DIR_REL=""
case "$IMG_DIR" in
  "$SEARCH_ROOT"/*) IMG_DIR_REL="$(basename "$IMG_DIR")" ;;
esac

search_for() {
  local needle="$1"
  if [[ "$SEARCHER" == "rg" ]]; then
    rg -q --fixed-strings "${RG_GLOBS[@]}" "$needle" "$SEARCH_ROOT" 2>/dev/null
  else
    local excludes=(
      --exclude-dir=node_modules
      --exclude-dir=.git
      --exclude-dir=Pods
      --exclude-dir=build
      --exclude-dir=.gradle
    )
    [[ -n "$IMG_DIR_REL" ]] && excludes+=(--exclude-dir="$IMG_DIR_REL")
    grep -rIlF "${excludes[@]}" "$needle" "$SEARCH_ROOT" >/dev/null 2>&1
  fi
}

# ─── Collect files (bash 3.2 compatible — macOS) ─────────────────────────────
FILES=()
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find -E "$IMG_DIR" -type f -iregex ".*$EXTS_REGEX" -print0 2>/dev/null || \
         find "$IMG_DIR" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.svg' -o -iname '*.bmp' -o -iname '*.heic' -o -iname '*.avif' \) -print0)

TOTAL=${#FILES[@]}
USED_COUNT=0
UNUSED_COUNT=0
USED_BYTES=0
UNUSED_BYTES=0
TOTAL_BYTES=0

if [[ $TOTAL -eq 0 ]]; then
  warn "No images found in $IMG_DIR"
  exit 0
fi

title "Scanning $TOTAL images..."
printf "\n"

i=0
for f in "${FILES[@]}"; do
  i=$((i + 1))
  base="$(basename "$f")"
  size_bytes=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
  size_human=$(human_size "$size_bytes")
  TOTAL_BYTES=$((TOTAL_BYTES + size_bytes))

  printf "\r${DIM}[%d/%d]${RESET} %-60s" "$i" "$TOTAL" "${base:0:60}"

  if search_for "$base"; then
    printf '%s\t%s\n' "$size_human" "$base" >> "$TMP_USED"
    USED_COUNT=$((USED_COUNT + 1))
    USED_BYTES=$((USED_BYTES + size_bytes))
  else
    printf '%s\t%s\n' "$size_human" "$base" >> "$TMP_UNUSED"
    printf '%s\n' "$f" >> "$TMP_UNUSED_PATHS"
    UNUSED_COUNT=$((UNUSED_COUNT + 1))
    UNUSED_BYTES=$((UNUSED_BYTES + size_bytes))
  fi
done
printf "\r%*s\r" 80 ""

USED_SIZE_H=$(human_size "$USED_BYTES")
UNUSED_SIZE_H=$(human_size "$UNUSED_BYTES")
TOTAL_SIZE_H=$(human_size "$TOTAL_BYTES")

sort -t$'\t' -k2 -o "$TMP_USED" "$TMP_USED"
sort -t$'\t' -k2 -o "$TMP_UNUSED" "$TMP_UNUSED"
sort -o "$TMP_UNUSED_PATHS" "$TMP_UNUSED_PATHS"

# ─── Report ──────────────────────────────────────────────────────────────────
title "Summary"
printf "\n"
printf "  ${BOLD}%-10s${RESET} ${DIM}│${RESET} %6s ${DIM}│${RESET} %10s\n" "Metric" "Count" "Size"
printf "  ${GRAY}%s${RESET}\n" "──────────┼────────┼───────────"
printf "  %-10s ${DIM}│${RESET} ${BOLD}%6d${RESET} ${DIM}│${RESET} ${BOLD}%10s${RESET}\n" "Total" "$TOTAL" "$TOTAL_SIZE_H"
printf "  ${GREEN}%-10s${RESET} ${DIM}│${RESET} ${GREEN}%6d${RESET} ${DIM}│${RESET} ${GREEN}%10s${RESET}\n" "Used" "$USED_COUNT" "$USED_SIZE_H"
printf "  ${RED}%-10s${RESET} ${DIM}│${RESET} ${RED}%6d${RESET} ${DIM}│${RESET} ${RED}%10s${RESET}\n" "Unused" "$UNUSED_COUNT" "$UNUSED_SIZE_H"
printf "\n"

title "Unused (${RED}$UNUSED_COUNT${RESET}${BOLD}${CYAN} — ${RED}$UNUSED_SIZE_H${BOLD}${CYAN})${RESET}"
printf "\n"
if [[ -s "$TMP_UNUSED" ]]; then
  while IFS=$'\t' read -r sz name; do
    printf "  ${RED}✗${RESET} ${DIM}%10s${RESET}  %s\n" "$sz" "$name"
  done < "$TMP_UNUSED"
else
  printf "  ${GREEN}None — every image referenced.${RESET}\n"
fi

title "Used (${GREEN}$USED_COUNT${RESET}${BOLD}${CYAN} — ${GREEN}$USED_SIZE_H${BOLD}${CYAN})${RESET}"
printf "\n"
if [[ -s "$TMP_USED" ]]; then
  while IFS=$'\t' read -r sz name; do
    printf "  ${GREEN}✓${RESET} ${DIM}%10s${RESET}  %s\n" "$sz" "$name"
  done < "$TMP_USED"
else
  printf "  ${DIM}None${RESET}\n"
fi

printf "\n"
hr
printf "  ${BOLD}Grand total:${RESET} %s across %d images\n" "$TOTAL_SIZE_H" "$TOTAL"
printf "  ${BOLD}Reclaimable:${RESET} ${RED}%s${RESET} from ${RED}%d${RESET} unused\n" "$UNUSED_SIZE_H" "$UNUSED_COUNT"
hr
printf "\n"

# ─── Delete prompt ───────────────────────────────────────────────────────────
if [[ $UNUSED_COUNT -eq 0 ]]; then
  ok "Nothing to clean up. ${BOLD}Done.${RESET}"
  exit 0
fi

printf "${BOLD}${YELLOW}⚠  About to delete %d files (%s).${RESET}\n" "$UNUSED_COUNT" "$UNUSED_SIZE_H"
printf "${DIM}   This action cannot be undone.${RESET}\n\n"
ask "Delete all unused images? [y/N]:"
read -r CONFIRM < /dev/tty

case "$(printf '%s' "$CONFIRM" | tr '[:upper:]' '[:lower:]')" in
  y|yes)
    printf "\n"
    deleted=0
    failed=0
    while IFS= read -r path; do
      if rm -f "$path" 2>/dev/null; then
        deleted=$((deleted + 1))
        printf "  ${RED}🗑${RESET}  ${DIM}%s${RESET}\n" "$(basename "$path")"
      else
        failed=$((failed + 1))
        err "Failed: $path"
      fi
    done < "$TMP_UNUSED_PATHS"
    printf "\n"
    ok "Deleted ${BOLD}$deleted${RESET} files, freed ${BOLD}$UNUSED_SIZE_H${RESET}"
    [[ $failed -gt 0 ]] && warn "$failed file(s) failed to delete"
    ;;
  *)
    printf "\n"
    ok "Kept all files. Nothing deleted."
    ;;
esac
CLEANIMGS_PAYLOAD_EOF
}

clean_unused_images() {
  header "🖼  Unused images"
  echo ""
  if [ ${#ALL_PROJECTS[@]} -eq 0 ]; then
    echo -e "  ${RED}❌ No projects found in $PROJECTS_DIR.${RESET}"
    return 1
  fi

  echo -e "  ${BOLD}Pick the project to scan${RESET}  ${DIM}↑/↓ move, Enter run, q quit${RESET}"
  echo ""

  # Reuse the main picker: each row carries the path as its "mode".
  MENU_KINDS=(); MENU_LABELS=(); MENU_DESCS=(); MENU_MODES=()
  local i
  for i in "${!ALL_PROJECTS[@]}"; do
    menu_item "${ALL_PROJECTS[$i]}" "" "$PROJECTS_DIR/${ALL_PROJECTS[$i]}"
  done
  menu_sep ""
  menu_item "Current directory" "$PWD" "$PWD"

  local target
  target=$(menu_choose) || target=""
  if [ -z "$target" ]; then
    echo ""
    echo -e "  ${YELLOW}Cancelled.${RESET}"
    return 0
  fi

  local payload_file
  payload_file=$(mktemp "${TMPDIR:-/tmp}/clean-imgs.XXXXXX.sh") || return 1
  imgs_payload > "$payload_file"
  chmod +x "$payload_file"

  log "unused images: running embedded cleanimgs in $target"
  ( cd "$target" && bash "$payload_file" )
  local rc=$?
  rm -f "$payload_file"
  return $rc
}

clean_orphan_app_data() {
  header "🗑  Orphaned app data"
  echo ""
  echo -e "  ${DIM}Building app inventory (LaunchServices + /Applications)...${RESET}"
  if ! orphan_build_inventory; then
    echo -e "  ${RED}❌ Could not build the app inventory. Aborting this mode.${RESET}"
    return 1
  fi
  echo -e "  ${DIM}$(wc -l < "$ORPHAN_IDS" | tr -d ' ') bundle ids, $(wc -l < "$ORPHAN_NAMES" | tr -d ' ') app names known.${RESET}"
  echo ""
  echo -e "  ${DIM}Scanning ~/Library for data with no installed owner...${RESET}"
  ORPHAN_SKIPPED_SMALL=0

  orphan_scan_dir "Application Support" "$HOME/Library/Application Support"
  orphan_scan_dir "Caches"              "$HOME/Library/Caches"
  orphan_scan_dir "Containers"          "$HOME/Library/Containers"
  orphan_scan_dir "Group Containers"    "$HOME/Library/Group Containers"
  orphan_scan_dir "Preferences"         "$HOME/Library/Preferences"
  orphan_scan_dir "Saved App State"     "$HOME/Library/Saved Application State"
  orphan_scan_dir "HTTP Storages"       "$HOME/Library/HTTPStorages"
  orphan_scan_dir "WebKit"              "$HOME/Library/WebKit"
  orphan_scan_dir "Logs"                "$HOME/Library/Logs"
  orphan_scan_dir "LaunchAgents"        "$HOME/Library/LaunchAgents"
  orphan_scan_dir "Cookies"             "$HOME/Library/Cookies"

  rm -rf "$ORPHAN_TMP"

  local total=${#ORPHAN_PATHS[@]}
  if [ "$total" -eq 0 ]; then
    echo ""
    echo -e "  ${GREEN}✅ No orphaned app data found.${RESET}"
    if [ "${ORPHAN_SKIPPED_SMALL:-0}" -gt 0 ]; then
      echo -e "  ${DIM}(${ORPHAN_SKIPPED_SMALL} item(s) under ${ORPHAN_MIN_KB}KB ignored)${RESET}"
    fi
    echo ""
    return 0
  fi

  # Sort indices by size, largest first.
  local order idx
  order=$(for idx in "${!ORPHAN_PATHS[@]}"; do
    echo "${ORPHAN_KB[$idx]} $idx"
  done | sort -rn | awk '{print $2}')

  local -a SORTED=()
  while IFS= read -r idx; do SORTED+=("$idx"); done <<< "$order"

  echo ""
  echo -e "  ${BOLD}${WHITE}Found $total item(s) with no installed owner${RESET}"
  if [ "${ORPHAN_SKIPPED_SMALL:-0}" -gt 0 ]; then
    echo -e "  ${DIM}(${ORPHAN_SKIPPED_SMALL} more under ${ORPHAN_MIN_KB}KB hidden — run with ORPHAN_MIN_KB=0 to see them)${RESET}"
  fi
  echo -e "  ${YELLOW}⚠️  Heuristic match. An app you reinstall later loses these settings,${RESET}"
  echo -e "  ${YELLOW}   and a headless tool (CLI, driver, plugin) can legitimately own one.${RESET}"
  echo ""
  echo -e "  ${DIM}↑/↓ move, Space select, a all, Enter confirm, q quit${RESET}"
  echo -e "  ${DIM}$(repeat_char '─' 74)${RESET}"

  # Rows in the picker mirror $SORTED, so an index maps straight back.
  local i
  multi_reset
  for i in "${SORTED[@]}"; do
    multi_item "$(printf '%-8s %s' "${ORPHAN_SIZES[$i]}" "${ORPHAN_LABELS[$i]:0:28}")" "${ORPHAN_KINDS[$i]}"
  done

  local -a TO_DELETE=()
  local sel_idx
  CHOSEN_IDX=$(menu_multi_choose) || CHOSEN_IDX=""
  while IFS= read -r sel_idx; do
    [ -n "$sel_idx" ] && TO_DELETE+=("${SORTED[$sel_idx]}")
  done <<< "$CHOSEN_IDX"

  if [ ${#TO_DELETE[@]} -eq 0 ]; then
    echo -e "  ${YELLOW}Nothing valid selected. Nothing deleted.${RESET}"
    echo ""
    return 0
  fi

  echo ""
  echo -e "  ${BOLD}${RED}About to delete ${#TO_DELETE[@]} item(s):${RESET}"
  for i in "${TO_DELETE[@]}"; do
    printf "    ${RED}✗${RESET} %-34s ${DIM}%s — %s${RESET}\n" \
      "${ORPHAN_LABELS[$i]:0:34}" "${ORPHAN_SIZES[$i]}" "${ORPHAN_PATHS[$i]}"
  done
  echo ""
  if ! confirm "$(echo -e "  ${BOLD}Type y to confirm deletion: ${RESET}")"; then
    echo -e "  ${YELLOW}Cancelled. Nothing deleted.${RESET}"
    echo ""
    return 0
  fi

  echo ""
  for i in "${TO_DELETE[@]}"; do
    nuke_path "orphan: ${ORPHAN_LABELS[$i]}" "${ORPHAN_PATHS[$i]}"
  done
  echo -e "   ${GREEN}✅ Orphaned app data cleaned${RESET}"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# First-time setup / load config
# ─────────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
  header "👋 First time setup"
  echo ""
  read -p "Enter the full path to your Projects folder: " PROJECTS_DIR < /dev/tty

  PROJECTS_DIR="${PROJECTS_DIR/#\~/$HOME}"

  if [ ! -d "$PROJECTS_DIR" ]; then
    echo -e "${RED}❌ Directory not found: $PROJECTS_DIR${RESET}"
    exit 1
  fi

  case "$(cd "$PROJECTS_DIR" && pwd)" in
    "/" | "$HOME" | "/Users" | "/Applications" | "/System" | "/Library")
      echo -e "${RED}❌ Refusing to use $PROJECTS_DIR as projects root — too broad / dangerous.${RESET}"
      exit 1
      ;;
  esac

  echo "$(cd "$PROJECTS_DIR" && pwd)" > "$CONFIG_FILE"
  echo -e "${GREEN}✅ Saved! You won't be asked again.${RESET}"

  SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  SHELL_RC="$HOME/.zshrc"
  if ! grep -q 'alias clean=' "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Clean command" >> "$SHELL_RC"
    echo "alias clean=\"bash $SCRIPT_PATH\"" >> "$SHELL_RC"
    echo -e "${GREEN}✅ 'clean' command installed globally.${RESET}"
    echo -e "${DIM}   Restart your terminal or run: source ~/.zshrc${RESET}"
  fi
  echo ""
  read -p "Press Enter to continue..." < /dev/tty
else
  PROJECTS_DIR=$(cat "$CONFIG_FILE")
  if [ ! -d "$PROJECTS_DIR" ]; then
    echo -e "${RED}❌ Saved directory no longer exists: $PROJECTS_DIR${RESET}"
    echo "Removing config. Run again to set a new path."
    rm "$CONFIG_FILE"
    exit 1
  fi
fi

# Re-validate projects dir on every run (in case config was edited)
case "$(cd "$PROJECTS_DIR" && pwd)" in
  "/" | "$HOME" | "/Users" | "/Applications" | "/System" | "/Library")
    echo -e "${RED}❌ PROJECTS_DIR ($PROJECTS_DIR) resolves to a dangerous path. Aborting.${RESET}"
    exit 1
    ;;
esac

# ─────────────────────────────────────────────────────────────
# Discover all project folders
# ─────────────────────────────────────────────────────────────
# Returns 0 if a folder name is on the permanent exclude list.
is_always_excluded() {
  local name="$1" ex
  for ex in "${ALWAYS_EXCLUDE[@]}"; do
    [ "$name" = "$ex" ] && return 0
  done
  return 1
}

ALL_PROJECTS=()
for dir in "$PROJECTS_DIR"/*/; do
  [ -d "$dir" ] || continue
  base="$(basename "$dir")"
  case "$base" in
    .*) continue ;;
  esac
  # Permanently excluded projects are never discovered, listed, or cleaned.
  if is_always_excluded "$base"; then
    log "EXCLUDED (always) $base"
    continue
  fi
  ALL_PROJECTS+=("$base")
done

DISK_USED=$(df -h / | tail -1 | awk '{print $3}')
DISK_FREE=$(df -h / | tail -1 | awk '{print $4}')
DISK_PCT=$(df -h / | tail -1 | awk '{print $5}')

header "🧹 clean"
echo ""
printf "  ${DIM}%-10s${RESET} %s\n" "Projects:" "${#ALL_PROJECTS[@]} found in $PROJECTS_DIR"
printf "  ${DIM}%-10s${RESET} %s\n" "Disk:" "$DISK_USED used ($DISK_PCT) — $DISK_FREE free"
if [ "$DRY_RUN" = true ]; then
  echo -e "  ${YELLOW}🟡 DRY RUN${RESET} ${DIM}— nothing will actually be deleted${RESET}"
fi
if [ "$AGGRESSIVE" = true ]; then
  echo -e "  ${MAGENTA}🔥 AGGRESSIVE${RESET} ${DIM}— also clears re-downloadable Docker/brew/go/cargo/archives${RESET}"
fi
echo ""
echo -e "  ${BOLD}${WHITE}Choose an action${RESET}  ${DIM}↑/↓ to move, Enter to run, q to quit${RESET}"
echo ""

menu_sep  "PROJECT BUILD ARTIFACTS"
menu_item "Clean all"               "projects + npm/uv/pods/brew/docker/~Caches" 1
menu_item "Clean all projects"      "node_modules/Pods/builds + Gradle/Xcode" 2
menu_item "Clean selected projects" "same, only projects you pick" 3
menu_item "Clean all except..."     "same, all except projects you pick" 4
menu_sep  "SYSTEM & LEFTOVERS"
menu_item "Clean programs data"     "~/Library leftovers of removed apps" 5
menu_item "Clean everything"        "Clean all + sims, emulator, old NDK/SDK" 6
menu_sep  "PROJECT ASSETS"
menu_item "Clean unused images"     "scan a project, delete unreferenced" 7
menu_sep  ""

CLEAN_MODE=$(menu_choose)
if [ -z "$CLEAN_MODE" ]; then
  echo ""
  echo -e "  ${YELLOW}Cancelled.${RESET}"
  exit 0
fi
echo ""

# Mode 7 is standalone: hand the chosen project over to cleanimgs.sh.
if [ "$CLEAN_MODE" = "7" ]; then
  clean_unused_images
  log "===== clean run finished (mode=7, unused images) ====="
  exit $?
fi

# Mode 5 is standalone: it only touches leftover app data, no projects
# and no dev caches, so it runs here and exits.
if [ "$CLEAN_MODE" = "5" ]; then
  clean_orphan_app_data
  log "===== clean run finished (mode=5, orphaned app data) ====="
  exit 0
fi

# Projects required for project-scoped modes.
if [ ${#ALL_PROJECTS[@]} -eq 0 ]; then
  echo -e "${RED}❌ No projects found in $PROJECTS_DIR.${RESET}"
  exit 1
fi

warn_running_ides

# Deep system/dev caches run for "clean all" (1) and "clean all" (6).
DO_DEEP_SYSTEM=false
if [ "$CLEAN_MODE" = "6" ]; then
  AGGRESSIVE=true
  KEEP_DOCKER_VOLUMES=true
fi
if [ "$CLEAN_MODE" = "1" ] || [ "$CLEAN_MODE" = "6" ]; then
  DO_DEEP_SYSTEM=true
fi

# ─────────────────────────────────────────────────────────────
# Selection (modes 3 & 4)
# ─────────────────────────────────────────────────────────────
SELECTED_PROJECTS=()
PICKED=()

if [ "$CLEAN_MODE" = "3" ] || [ "$CLEAN_MODE" = "4" ]; then
  echo ""
  if [ "$CLEAN_MODE" = "4" ]; then
    echo -e "  ${BOLD}📂 Pick the projects to KEEP${RESET}  ${DIM}↑/↓ move, Space select, a all, Enter confirm${RESET}"
  else
    echo -e "  ${BOLD}📂 Pick the projects to clean${RESET}  ${DIM}↑/↓ move, Space select, a all, Enter confirm${RESET}"
  fi
  echo ""
  multi_reset
  for i in "${!ALL_PROJECTS[@]}"; do
    PSIZE=$(dir_size "$PROJECTS_DIR/${ALL_PROJECTS[$i]}/node_modules")
    multi_item "${ALL_PROJECTS[$i]}" "node_modules: $PSIZE"
  done

  CHOSEN_IDX=$(menu_multi_choose) || CHOSEN_IDX=""
  while IFS= read -r idx; do
    [ -n "$idx" ] && PICKED+=("${ALL_PROJECTS[$idx]}")
  done <<< "$CHOSEN_IDX"

  if [ ${#PICKED[@]} -eq 0 ]; then
    echo -e "${RED}❌ No valid projects selected.${RESET}"
    exit 1
  fi

  if [ "$CLEAN_MODE" = "3" ]; then
    SELECTED_PROJECTS=("${PICKED[@]}")
  else
    for p in "${ALL_PROJECTS[@]}"; do
      SKIP=false
      for k in "${PICKED[@]}"; do
        [ "$p" = "$k" ] && SKIP=true && break
      done
      [ "$SKIP" = false ] && SELECTED_PROJECTS+=("$p")
    done
  fi
elif [ "$CLEAN_MODE" = "6" ]; then
  SELECTED_PROJECTS=("${ALL_PROJECTS[@]}")
else
  SELECTED_PROJECTS=("${ALL_PROJECTS[@]}")
fi

# Filter selected projects to those that actually look like projects.
VALIDATED_PROJECTS=()
REJECTED_PROJECTS=()
if [ ${#SELECTED_PROJECTS[@]} -gt 0 ]; then
  for p in "${SELECTED_PROJECTS[@]}"; do
    if is_project_dir "$PROJECTS_DIR/$p"; then
      VALIDATED_PROJECTS+=("$p")
    else
      REJECTED_PROJECTS+=("$p")
    fi
  done
fi
SELECTED_PROJECTS=(${VALIDATED_PROJECTS[@]+"${VALIDATED_PROJECTS[@]}"})

# Compute skipped (= not in SELECTED_PROJECTS) for the report
SKIPPED_PROJECTS=()
if [ ${#ALL_PROJECTS[@]} -gt 0 ]; then
  for p in "${ALL_PROJECTS[@]}"; do
    found=false
    if [ ${#SELECTED_PROJECTS[@]} -gt 0 ]; then
      for s in "${SELECTED_PROJECTS[@]}"; do
        [ "$p" = "$s" ] && found=true && break
      done
    fi
    [ "$found" = false ] && SKIPPED_PROJECTS+=("$p")
  done
fi

# ─────────────────────────────────────────────────────────────
# Summary + confirm
# ─────────────────────────────────────────────────────────────
header "📋 Summary"
echo ""
if [ "$CLEAN_MODE" = "4" ]; then
  echo -e "  ${GREEN}🛡️  Keeping:${RESET}  $(join_list "${PICKED[@]+${PICKED[@]}}")"
fi
if [ "$CLEAN_MODE" != "6" ]; then
  if [ ${#SELECTED_PROJECTS[@]} -gt 0 ]; then
    echo -e "  ${RED}🧹 Cleaning projects:${RESET} $(join_list "${SELECTED_PROJECTS[@]}")"
  else
    echo -e "  ${RED}🧹 Cleaning projects:${RESET} ${DIM}(none — nothing matched a real project)${RESET}"
  fi
  if [ ${#REJECTED_PROJECTS[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}⚠️  Not a project (skipped):${RESET} $(join_list "${REJECTED_PROJECTS[@]}")"
  fi
fi
echo ""
sum_line() { printf "  ${RED}✗${RESET} %-44s ${DIM}%s${RESET}\n" "$1" "$2"; }
echo -e "  ${BOLD}Will delete:${RESET}"
if [ ${#SELECTED_PROJECTS[@]} -gt 0 ]; then
  sum_line "Per project: node_modules" "npm install to restore"
  sum_line "Per project: ios/Pods, ios/build (pod deintegrate)" "pod install to restore"
  sum_line "Per project: android/build, app/build, .gradle, .cxx" "rebuilt on next build"
fi
sum_line "~/.gradle caches + daemons" "$(dir_size "$HOME/.gradle/caches")"
sum_line "Xcode DerivedData + Xcode cache" "$(dir_size "$HOME/Library/Developer/Xcode/DerivedData")"
sum_line "Xcode iOS DeviceSupport" "$(dir_size "$HOME/Library/Developer/Xcode/iOS DeviceSupport") (re-made on device plug-in)"
sum_line "Unavailable simulators + CoreSimulator caches" ""
sum_line "Trash, Watchman, Metro temp" "$(dir_size "$HOME/.Trash")"
if [ "$DO_DEEP_SYSTEM" = true ]; then
  sum_line "npm/yarn/pnpm/bun caches" "$(dir_size "$HOME/.npm")"
  sum_line "CocoaPods cache" "$(dir_size "$HOME/Library/Caches/CocoaPods")"
  sum_line "pip + uv caches (~/.cache/uv)" "$(dir_size "$HOME/.cache/uv")"
  sum_line "SwiftPM / Carthage caches" ""
  sum_line "Homebrew old versions + downloads" ""
  sum_line "Docker build cache, unused images/containers" "volumes kept"
  sum_line "Android Studio / JetBrains / VS Code / Cursor caches" ""
  sum_line "~/Library/Caches (protected apps kept), logs, crash reports" "$(dir_size "$HOME/Library/Caches")"
fi
if [ "$CLEAN_MODE" = "6" ]; then
  sum_line "ALL iOS simulator devices + runtimes" "$(dir_size "$HOME/Library/Developer/CoreSimulator")"
  sum_line "Android emulator, system-images, AVDs" "$(dir_size "$ANDROID_SDK/emulator")+"
  sum_line "NDKs not in: ${KEEP_NDK[*]}, >=28" "$(dir_size "$ANDROID_SDK/ndk") total now"
  sum_line "build-tools not in: ${KEEP_BUILD_TOOLS[*]}, >=35; all -rc" "$(dir_size "$ANDROID_SDK/build-tools") total now"
  sum_line "Android platforms < API 30, SDK sources" ""
  sum_line "Go / Cargo module caches, Xcode Archives" ""
  sum_line "CoreDevice service cache" ""
fi
echo ""
echo -e "  ${DIM}Gradle daemons stop first so ./gradlew clean works afterward.${RESET}"
echo ""
if [ ${#SELECTED_PROJECTS[@]} -eq 0 ] && [ "$DO_DEEP_SYSTEM" = false ]; then
  echo -e "${YELLOW}Nothing selected to clean. Exiting.${RESET}"
  exit 0
fi
if ! confirm "Continue? (y/n): "; then
  echo -e "${YELLOW}Cancelled.${RESET}"
  exit 0
fi

is_selected() {
  local project="$1"
  for p in "${SELECTED_PROJECTS[@]}"; do
    [ "$p" = "$project" ] && return 0
  done
  return 1
}

BEFORE=$(df -k / | tail -1 | awk '{print $4}')
STEP=0

# Tracking vars (project report)
ANDROID_PROJECTS=()
ANDROID_SKIPPED=()
NODE_PROJECTS=()
NODE_PROJECT_SIZES=()
NODE_SKIPPED=()
POD_PROJECTS=()
POD_SKIPPED=()
IOS_PROJECTS=()
IOS_SKIPPED=()
DERIVED_SIZE="—"
XCODE_CACHE_SIZE="—"

TOTAL_STEPS=1  # stop gradle daemons
[ ${#SELECTED_PROJECTS[@]} -gt 0 ] && TOTAL_STEPS=$((TOTAL_STEPS + 4))
TOTAL_STEPS=$((TOTAL_STEPS + 5))  # global dev-tool caches, all modes
[ "$DO_DEEP_SYSTEM" = true ] && TOTAL_STEPS=$((TOTAL_STEPS + 7))
[ "$CLEAN_MODE" = "6" ] && TOTAL_STEPS=$((TOTAL_STEPS + 4))

next_step() {
  STEP=$((STEP + 1))
  local bar_w=24
  local filled=$((STEP * bar_w / TOTAL_STEPS))
  local empty=$((bar_w - filled))
  echo ""
  echo -e "${DIM}[${STEP}/${TOTAL_STEPS}]${RESET} ${CYAN}$(repeat_char '▓' "$filled")${GRAY:-$DIM}$(repeat_char '░' "$empty")${RESET} ${BOLD}${WHITE}$1${RESET}"
}

# ─────────────────────────────────────────────────────────────
# 0. Stop Gradle daemons FIRST so later cache deletion is clean.
# ─────────────────────────────────────────────────────────────
next_step "Stopping Gradle daemons..."
stop_gradle_daemons
echo -e "   ${GREEN}✅ Daemons stopped${RESET}"

# ── Per-project artifacts (modes 1-4) ────────────────────────
if [ ${#SELECTED_PROJECTS[@]} -gt 0 ]; then
  # Android build folders
  next_step "Removing Android build folders..."
  for project in "${SELECTED_PROJECTS[@]}"; do
    cleaned_any=false
    for sub in "android/app/build" "android/build" "android/.gradle" "android/.cxx"; do
      dir="$PROJECTS_DIR/$project/$sub"
      if [ -d "$dir" ]; then
        echo -e "   ${DIM}$project ($sub)${RESET}"
        safe_rm "$dir"
        cleaned_any=true
      fi
    done
    if [ "$cleaned_any" = true ]; then
      ANDROID_PROJECTS+=("$project")
    else
      ANDROID_SKIPPED+=("$project")
    fi
  done
  echo -e "   ${GREEN}✅ ${#ANDROID_PROJECTS[@]} project(s) cleaned${RESET}"

  # node_modules
  next_step "Removing node_modules..."
  for project in "${SELECTED_PROJECTS[@]}"; do
    dir="$PROJECTS_DIR/$project/node_modules"
    if [ -d "$dir" ]; then
      SIZE=$(dir_size "$dir")
      echo -e "   ${DIM}$project ($SIZE)${RESET}"
      if safe_rm "$dir"; then
        NODE_PROJECTS+=("$project")
        NODE_PROJECT_SIZES+=("$SIZE")
      else
        NODE_SKIPPED+=("$project")
      fi
    else
      NODE_SKIPPED+=("$project")
    fi
  done
  echo -e "   ${GREEN}✅ ${#NODE_PROJECTS[@]} project(s) cleaned${RESET}"

  # Pod deintegrate
  next_step "Running pod deintegrate..."
  for project in "${SELECTED_PROJECTS[@]}"; do
    dir="$PROJECTS_DIR/$project/ios"
    if [ -d "$dir" ] && [ -f "$dir/Podfile" ]; then
      if [ "$DRY_RUN" = true ]; then
        echo -e "   ${YELLOW}🟡 would deintegrate:${RESET} $project"
        POD_PROJECTS+=("$project")
      else
        echo -e "   ${DIM}$project${RESET}"
        if command -v pod >/dev/null 2>&1; then
          (cd "$dir" && pod deintegrate 2>/dev/null) && POD_PROJECTS+=("$project") || POD_SKIPPED+=("$project")
        else
          echo -e "   ${YELLOW}pod not installed, skipping${RESET}"
          POD_SKIPPED+=("$project")
        fi
      fi
    else
      POD_SKIPPED+=("$project")
    fi
  done
  echo -e "   ${GREEN}✅ ${#POD_PROJECTS[@]} project(s) deintegrated${RESET}"

  # iOS build folders + Pods
  next_step "Removing iOS build folders..."
  for project in "${SELECTED_PROJECTS[@]}"; do
    cleaned_any=false
    for sub in "ios/build" "ios/Pods" "ios/DerivedData"; do
      dir="$PROJECTS_DIR/$project/$sub"
      if [ -d "$dir" ]; then
        echo -e "   ${DIM}$project ($sub)${RESET}"
        safe_rm "$dir"
        cleaned_any=true
      fi
    done
    if [ "$cleaned_any" = true ]; then
      IOS_PROJECTS+=("$project")
    else
      IOS_SKIPPED+=("$project")
    fi
  done
  echo -e "   ${GREEN}✅ ${#IOS_PROJECTS[@]} project(s) cleaned${RESET}"
fi

# ── Global dev-tool caches (all modes) ───────────────────────
next_step "Removing Gradle caches (version dirs + dependencies)..."
clean_gradle

next_step "Removing Xcode DerivedData..."
if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
  DERIVED_SIZE=$(dir_size "$HOME/Library/Developer/Xcode/DerivedData")
  for d in "$HOME/Library/Developer/Xcode/DerivedData"/*; do
    [ -e "$d" ] || continue
    safe_rm "$d"
  done
  echo -e "   ${GREEN}✅ Freed $DERIVED_SIZE${RESET}"
else
  echo -e "   ${DIM}Not found, skipping${RESET}"
fi

next_step "Removing Xcode caches & simulator junk..."
XCODE_CACHE_SIZE=$(dir_size "$HOME/Library/Caches/com.apple.dt.Xcode")
safe_rm "$HOME/Library/Caches/com.apple.dt.Xcode"
clean_xcode_deep
echo -e "   ${GREEN}✅ Xcode cache: $XCODE_CACHE_SIZE${RESET}"

next_step "Emptying Trash..."
clean_trash

next_step "Clearing Watchman & React Native temp caches..."
clean_rn_temp

# ── Deep system + dev caches (modes 1 & 5) ───────────────────
if [ "$DO_DEEP_SYSTEM" = true ]; then
  next_step "Clearing package-manager caches (npm/yarn/pnpm/pip/Pods)..."
  clean_pkg_caches

  next_step "Cleaning Homebrew..."
  clean_brew

  next_step "Pruning Docker..."
  clean_docker

  next_step "Clearing Android Studio / JetBrains caches..."
  clean_android_studio

  next_step "Clearing editor (VS Code / Cursor) caches..."
  clean_editor_caches

  next_step "Clearing logs, crash reports & QuickLook thumbnails..."
  clean_logs_misc

  next_step "Cleaning macOS caches (~/Library/Caches, with protections)..."
  clean_macos_caches
fi

if [ "$CLEAN_MODE" = "6" ]; then
  next_step "Deleting ALL iOS simulator devices + runtimes..."
  clean_ios_simulators_all

  next_step "Deleting Android emulator, system images, AVDs..."
  clean_android_emulator

  next_step "Pruning Android SDK (NDK/build-tools/platforms unused by RN >= 0.65)..."
  clean_android_sdk_old

  next_step "Clearing CoreDevice service cache..."
  nuke_path "CoreDevice service cache" "$HOME/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches"
fi

AFTER=$(df -k / | tail -1 | awk '{print $4}')
FREED_KB=$((AFTER - BEFORE))
FREED_GB=$(echo "scale=2; $FREED_KB / 1048576" | bc)
NEW_FREE=$(df -h / | tail -1 | awk '{print $4}')

# ─────────────────────────────────────────────
# FINAL REPORT
# ─────────────────────────────────────────────
echo ""
echo ""
echo -e "${BOLD}${CYAN}$(printf '%.0s━' {1..52})${RESET}"
echo -e "${BOLD}${WHITE}   🧹  CLEAN REPORT${RESET}"
echo -e "${BOLD}${CYAN}$(printf '%.0s━' {1..52})${RESET}"

# Projects section
if [ ${#SELECTED_PROJECTS[@]} -gt 0 ] || [ ${#SKIPPED_PROJECTS[@]} -gt 0 ]; then
  echo ""
  echo -e "  ${BOLD}${MAGENTA}◆ PROJECTS${RESET}"
  echo -e "  ${DIM}$(printf '%.0s─' {1..48})${RESET}"

  if [ ${#NODE_PROJECTS[@]} -gt 0 ]; then
    echo -e "  ${BOLD}${WHITE}node_modules${RESET}"
    for i in "${!NODE_PROJECTS[@]}"; do
      printf "    ${GREEN}✅${RESET} %-30s ${DIM}%s${RESET}\n" "${NODE_PROJECTS[$i]}" "${NODE_PROJECT_SIZES[$i]}"
    done
  fi

  if [ ${#ANDROID_PROJECTS[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}${WHITE}Android builds${RESET}"
    for p in "${ANDROID_PROJECTS[@]}"; do
      printf "    ${GREEN}✅${RESET} %-30s ${DIM}cleaned${RESET}\n" "$p"
    done
  fi

  if [ ${#IOS_PROJECTS[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}${WHITE}iOS builds${RESET}"
    for p in "${IOS_PROJECTS[@]}"; do
      printf "    ${GREEN}✅${RESET} %-30s ${DIM}cleaned${RESET}\n" "$p"
    done
  fi

  if [ ${#POD_PROJECTS[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}${WHITE}CocoaPods${RESET}"
    for p in "${POD_PROJECTS[@]}"; do
      printf "    ${GREEN}✅${RESET} %-30s ${DIM}deintegrated${RESET}\n" "$p"
    done
  fi

  if [ ${#SKIPPED_PROJECTS[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}🛡  Kept / not selected${RESET}"
    for p in "${SKIPPED_PROJECTS[@]}"; do
      printf "    ${YELLOW}—${RESET}  %s\n" "$p"
    done
  fi
fi

# System & tools section
echo ""
echo -e "  ${DIM}$(printf '%.0s─' {1..48})${RESET}"
echo -e "  ${BOLD}${MAGENTA}◆ SYSTEM & DEV CACHES${RESET}"
echo -e "  ${DIM}$(printf '%.0s─' {1..48})${RESET}"

printf "  ${GREEN}✅${RESET} %-34s ${DIM}%s${RESET}\n" "Xcode DerivedData" "$DERIVED_SIZE"
printf "  ${GREEN}✅${RESET} %-34s ${DIM}%s${RESET}\n" "Xcode app cache" "$XCODE_CACHE_SIZE"

if [ ${#DEEP_LABELS[@]} -gt 0 ]; then
  for i in "${!DEEP_LABELS[@]}"; do
    printf "  ${GREEN}✅${RESET} %-34s ${DIM}%s${RESET}\n" "${DEEP_LABELS[$i]}" "${DEEP_VALUES[$i]}"
  done
fi

echo ""
echo -e "  ${BOLD}${CYAN}$(printf '%.0s─' {1..48})${RESET}"
if [ "$DRY_RUN" = true ]; then
  echo -e "  ${BOLD}${YELLOW}  🟡 DRY RUN — no changes were made${RESET}"
else
  echo -e "  ${BOLD}${GREEN}  💾  Freed ≈ ${FREED_GB} GB${RESET}          ${BOLD}${WHITE}🖴  Free now: ${NEW_FREE}${RESET}"
fi
echo -e "  ${BOLD}${CYAN}$(printf '%.0s─' {1..48})${RESET}"
echo ""
echo -e "  ${DIM}Restore projects: 'npm install' (or yarn/pnpm) and 'pod install'.${RESET}"
echo -e "  ${DIM}'./gradlew clean' works — daemons stopped, wrapper preserved.${RESET}"
echo -e "  ${DIM}Tip: run with -a/--aggressive to also clear Docker images, brew --prune=all,${RESET}"
echo -e "  ${DIM}     go/cargo module caches and Xcode Archives. Log: $LOG_FILE${RESET}"
echo ""
log "===== clean run finished (mode=$CLEAN_MODE) ====="
