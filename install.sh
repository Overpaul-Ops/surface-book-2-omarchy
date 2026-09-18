#!/usr/bin/env bash
#
# install.sh — one entry point for the whole setup
#
#     ./install.sh                  show status, then ask what to do
#     ./install.sh --all            run everything that can run right now
#     ./install.sh --status         show status and exit
#     ./install.sh --dry-run        show what would happen, change nothing
#     ./install.sh --step N         run exactly one step
#
# The setup cannot be done in one go, and no script can change that: three
# points require a reboot before the next step means anything. This keeps
# track of where you are, does everything possible up to the next boundary,
# and picks up there when you run it again.
#
# State is read from the system, not from a file it wrote earlier. So it
# still tells the truth if you did some of it by hand, re-cloned the repo,
# or came back a month later.
#
# Part of https://github.com/<you>/surface-book-2-omarchy — MIT licensed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="menu"
ONLY_STEP=""
ASSUME_YES=0
WITH_DEFAULT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --all)          MODE="all" ;;
        --status)       MODE="status" ;;
        --dry-run)      MODE="dryrun" ;;
        --step)         ONLY_STEP="${2:-}"; MODE="one"; shift ;;
        --yes|-y)       ASSUME_YES=1 ;;
        --with-default) WITH_DEFAULT=1 ;;
        -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)              printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

c_b=$'\033[1;34m'; c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_d=$'\033[2m'; c_0=$'\033[0m'

say() { printf '\n%s==> %s%s\n' "$c_b" "$*" "$c_0"; }
die() { printf '\n%sABORT: %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    printf '%s [y/N] ' "$1"
    read -r a
    case "$a" in [yYjJ]*) return 0 ;; *) return 1 ;; esac
}

[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not with sudo. The steps call sudo themselves, and the AUR helper refuses to run as root."

# ===========================================================================
# State detection — everything below reads the system, nothing is remembered
# ===========================================================================

has_dgpu()      { [ -n "$(lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]:/ && $3 ~ /^10de:/ { print $1; exit }')" ]; }
on_surface()    { case "$(uname -r)" in *surface*) return 0 ;; *) return 1 ;; esac; }
surface_pkg()   { for d in /usr/lib/modules/*/; do [ -e "${d}pkgbase" ] || continue; case "$(cat "${d}pkgbase")" in *surface*) cat "${d}pkgbase"; return 0 ;; esac; done; return 1; }

# Match on the function that makes this handler ours, not just on the repo
# URL in the header. That way a handler someone adapted by hand, or one
# installed before this repo existed, is still recognised.
step1_done()    { grep -qsE 'gpu_holders|surface-book-2-omarchy' /etc/surface-dtx/detach.sh; }
step1_pending_reboot() {
    step1_done || return 1
    has_dgpu   || return 1
    case "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" in *mesa*) return 1 ;; *) return 0 ;; esac
}

step2_done()    { surface_pkg >/dev/null; }
step2_pending_reboot() { step2_done && ! on_surface; }

step3_done()    { [ -d "$HOME/.config/omarchy/plugins/io.github.frostmute.tablet-mode" ] \
               && [ -d "$HOME/.config/omarchy/plugins/io.github.frostmute.tablet-keyboard" ]; }
step3_pending_reboot() {
    step3_done || return 1
    getent group input 2>/dev/null | grep -q "[:,]${USER}\$\|[:,]${USER}," || return 1
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input && return 1
    return 0
}

step4_done()    { [ -x /usr/local/bin/surface-health-check ] && [ -f /etc/pacman.d/hooks/99-surface-health.hook ]; }

step5_done()    { [ -f /etc/limine-entry-tool.d/zz-surface-first.conf ]; }

# ===========================================================================
# Status
# ===========================================================================

STEPS=(
    "1|Detach|Detach and re-attach the display safely|scripts/01-detach-setup.sh"
    "2|Kernel|linux-surface, for the touchscreen|scripts/02-kernel-install.sh"
    "3|Tablet|On-screen keyboard, trackpad, rotation|scripts/03-tablet-setup.sh"
    "4|Maintenance|Health check after every update|scripts/04-maintenance-setup.sh"
    "5|Default kernel|Boot linux-surface without picking it|scripts/05-default-kernel.sh"
)

# Prints: state name, and sets REASON
step_state() {
    case "$1" in
        1) if step1_pending_reboot; then echo reboot
           elif step1_done;          then echo done
           elif [ ! -e /dev/surface/dtx ]; then REASON="needs the linux-surface kernel first (step 2)"; echo blocked
           else echo todo; fi ;;
        2) if step2_pending_reboot; then echo reboot
           elif step2_done;          then echo done
           else echo todo; fi ;;
        3) if step3_pending_reboot; then echo reboot
           elif step3_done;          then echo done
           elif ! on_surface;        then REASON="boot the linux-surface kernel first"; echo blocked
           else echo todo; fi ;;
        4) step4_done && echo done || echo todo ;;
        5) if step5_done;      then echo done
           elif ! step2_done;  then REASON="needs step 2"; echo blocked
           elif ! on_surface;  then REASON="boot linux-surface at least once first"; echo blocked
           else echo todo; fi ;;
    esac
}

print_status() {
    printf '\n%sSurface Book 2 on Omarchy — setup status%s\n\n' "$c_b" "$c_0"
    local n name desc _s
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r n name desc _s <<<"$entry"
        REASON=""
        case "$(step_state "$n")" in
            done)    printf '  %s[✓]%s  %-14s %s\n' "$c_g" "$c_0" "$name" "$desc" ;;
            todo)    printf '  [ ]  %-14s %s\n' "$name" "$desc" ;;
            reboot)  printf '  %s[!]%s  %-14s %s\n       %s%s%s\n' "$c_y" "$c_0" "$name" "$desc" \
                            "$c_y" "installed, but needs a reboot to take effect" "$c_0" ;;
            blocked) printf '  %s[–]%s  %-14s %s\n       %s%s%s\n' "$c_d" "$c_0" "$name" "$desc" \
                            "$c_d" "$REASON" "$c_0" ;;
        esac
    done

    printf '\n  %srunning kernel:%s %s' "$c_d" "$c_0" "$(uname -r)"
    on_surface && printf ' %s(touchscreen available)%s\n' "$c_g" "$c_0" || printf ' %s(no touchscreen on this kernel)%s\n' "$c_d" "$c_0"

    if step5_done && ! on_surface; then
        printf '  %snote: linux-surface is the default but you booted something else%s\n' "$c_y" "$c_0"
    fi

    # What is the single most useful next action?
    NEXT=""
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r n name desc _s <<<"$entry"
        case "$(step_state "$n")" in
            reboot) NEXT="reboot"; NEXT_WHY="step $n ($name) needs it"; break ;;
        esac
    done
    if [ -z "$NEXT" ]; then
        for entry in "${STEPS[@]}"; do
            IFS='|' read -r n name desc _s <<<"$entry"
            [ "$n" = "5" ] && continue
            [ "$(step_state "$n")" = "todo" ] && { NEXT="run"; NEXT_N="$n"; NEXT_NAME="$name"; break; }
        done
    fi

    printf '\n'
    case "$NEXT" in
        reboot) printf '  %sNext: reboot (%s), then run ./install.sh again.%s\n' "$c_y" "$NEXT_WHY" "$c_0"
                on_surface || printf '  %sPick the linux-surface entry in the boot menu.%s\n' "$c_y" "$c_0" ;;
        run)    printf '  Next: step %s — %s\n' "$NEXT_N" "$NEXT_NAME" ;;
        *)      printf '  %sNothing left to do.%s\n' "$c_g" "$c_0"
                step5_done || printf '  %sOptional: step 5 makes linux-surface the default boot entry.%s\n' "$c_d" "$c_0" ;;
    esac
    printf '\n'
}

# ===========================================================================
# Running a step
# ===========================================================================

run_step() {
    local n="$1" name script
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r sn name _d script <<<"$entry"
        [ "$sn" = "$n" ] && break
    done
    [ -f "$REPO/$script" ] || die "$script not found"

    REASON=""
    local state; state="$(step_state "$n")"
    case "$state" in
        done)    printf '  Step %s (%s) is already done — skipping.\n' "$n" "$name"; return 0 ;;
        blocked) printf '  %sStep %s (%s) cannot run yet: %s%s\n' "$c_y" "$n" "$name" "$REASON" "$c_0"; return 1 ;;
        reboot)  printf '  %sStep %s (%s) is installed but needs a reboot before it works.%s\n' "$c_y" "$n" "$name" "$c_0"; return 2 ;;
    esac

    if [ "$MODE" = "dryrun" ]; then
        printf '  %swould run:%s bash %s\n' "$c_d" "$c_0" "$script"
        return 0
    fi

    say "Step $n: $name"
    bash "$REPO/$script" || die "step $n failed. Nothing further will run."
    return 0
}

offer_reboot() {
    printf '\n%s%s%s\n' "$c_y" "A reboot is needed before the next step means anything." "$c_0"
    if ! on_surface && step2_done; then
        printf '%sIn the boot menu, press an arrow key to stop the countdown and pick linux-surface.%s\n' "$c_y" "$c_0"
    fi
    [ "$MODE" = "dryrun" ] && { printf '  (dry run — not rebooting)\n'; return; }
    if confirm "Reboot now?"; then
        if command -v omarchy-system-reboot >/dev/null; then omarchy-system-reboot; else systemctl reboot; fi
    else
        printf '\nWhen you are ready:  reboot\nThen run:            ./install.sh\n\n'
    fi
}

# ===========================================================================
# Main
# ===========================================================================

print_status
[ "$MODE" = "status" ] && exit 0

case "$MODE" in
    one)
        case "$ONLY_STEP" in 1|2|3|4|5) ;; *) die "--step takes 1..5" ;; esac
        run_step "$ONLY_STEP"
        ;;

    all|dryrun)
        [ "$MODE" = "dryrun" ] && printf '%sDry run — nothing will be changed.%s\n' "$c_d" "$c_0"
        for n in 1 2 3 4; do
            REASON=""
            case "$(step_state "$n")" in
                done) continue ;;
                reboot)   printf '\n  Step %s is waiting for a reboot. Stopping here.\n' "$n"; offer_reboot; exit 0 ;;
                blocked)  printf '\n  Step %s cannot run yet: %s\n' "$n" "$REASON"
                          printf '  This usually means a reboot is needed first.\n'; offer_reboot; exit 0 ;;
                todo)     run_step "$n" || { offer_reboot; exit 0; } ;;
            esac
            # A step that just ran may now be waiting for a reboot.
            if [ "$MODE" != "dryrun" ]; then
                case "$n" in
                    1) step1_pending_reboot && { printf '\n  Step 1 is installed but needs a reboot.\n'; offer_reboot; exit 0; } ;;
                    2) step2_pending_reboot && { printf '\n  Step 2 is installed. You must boot linux-surface before step 3.\n'; offer_reboot; exit 0; } ;;
                    3) step3_pending_reboot && { printf '\n  Step 3 is installed but the input group needs a reboot.\n'; offer_reboot; exit 0; } ;;
                esac
            fi
        done

        if [ "$WITH_DEFAULT" = "1" ]; then
            [ "$(step_state 5)" = "todo" ] && run_step 5
        elif [ "$(step_state 5)" = "todo" ]; then
            printf '\n  %sStep 5 (make linux-surface the default) was not run.%s\n' "$c_d" "$c_0"
            printf '  %sDo it once the kernel has behaved for a few days:%s\n' "$c_d" "$c_0"
            printf '  %s  ./install.sh --step 5%s\n' "$c_d" "$c_0"
        fi

        print_status
        ;;

    menu)
        printf 'What would you like to do?\n\n'
        printf '  a) everything that can run right now\n'
        printf '  1) step 1 — detach\n'
        printf '  2) step 2 — kernel\n'
        printf '  3) step 3 — tablet mode\n'
        printf '  4) step 4 — maintenance\n'
        printf '  5) step 5 — make linux-surface the default\n'
        printf '  d) dry run (show what would happen)\n'
        printf '  q) quit\n\n'
        printf 'Choice: '
        read -r choice
        case "$choice" in
            a|A) exec "$0" --all ;;
            1|2|3|4|5) run_step "$choice"; print_status ;;
            d|D) exec "$0" --dry-run ;;
            q|Q|'') exit 0 ;;
            *) die "not a choice: $choice" ;;
        esac
        ;;
esac
