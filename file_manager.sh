#!/bin/bash
trap 'tput cnorm; clear; exit' INT TERM EXIT

# ══════════════════════════════════════════════
#         TERMINAL BASED FILE MANAGER
#   Navigate | Search | Copy | Rename | Stats
# ══════════════════════════════════════════════

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# Prefer a UTF-8 locale so filename/column-width math (${#var}) counts
# glyphs rather than raw bytes for the emoji icons and the "…"
# truncation marker used below. Only switches if a matching locale is
# actually installed, so this can never break on a system without one.
for _fm_locale in "${LANG:-}" "en_US.UTF-8" "C.UTF-8" "C.utf8"; do
    [ -z "$_fm_locale" ] && continue
    if locale -a 2>/dev/null | grep -qi "^${_fm_locale}$"; then
        export LC_ALL="$_fm_locale"
        break
    fi
done
unset _fm_locale

# ── State ──────────────────────────────────────
CURRENT_DIR="$HOME"
CURSOR=0
PREV_CURSOR=-1
CLIPBOARD=()
CLIPBOARD_OP=""
declare -A SELECTED_SET      # keyed by item NAME (not index) -> survives reloads safely
NEED_RELOAD=1                 # run mapfile+ls to refresh items[]
NEED_REFRESH=1                # clear screen and redraw everything
items=()
declare -A SIZE_CACHE         # cached sizes, keyed by item index (always rebuilt on reload)

# ── Layout state (recomputed every loop tick) ──
HEADER_LINES=6
FOOTER_LINES=6                # must equal exact number of lines show_keys() prints
TERM_LINES=24
TERM_COLS=80
VISIBLE_ROWS=0                # how many item rows fit on screen
SCROLL_OFFSET=0                # index of first visible item
NAME_W=30                     # dynamic filename column width
PROMPT_ROW=0                  # fixed row used for prompts / flash messages
PROMPT_REPLY=""                # set by prompt_input()
MIN_COLS=40
PENDING_ANCHOR=""              # item NAME the cursor should re-find after a reload
                               # (e.g. a rename target) — a raw numeric CURSOR
                               # goes stale the instant items[] is re-sorted.

# ──────────────────────────────────────────────
# Get icon based on file type
# ──────────────────────────────────────────────
get_icon() {
    local item="$1" full="$2"
    [ -d "$full" ] && { echo "📁"; return; }
    local ext="${item##*.}"
    case "${ext,,}" in
        txt|md|log|rst)                echo "📝" ;;
        sh|bash|zsh)                   echo "⚙ " ;;
        py)                            echo "🐍" ;;
        js|ts|jsx|tsx)                 echo "📜" ;;
        html|css|scss)                 echo "🌐" ;;
        jpg|jpeg|png|gif|svg|bmp|webp) echo "🖼 " ;;
        mp4|mkv|avi|mov|webm)          echo "🎬" ;;
        mp3|wav|flac|ogg|aac)          echo "🎵" ;;
        zip|tar|gz|rar|7z|xz)          echo "📦" ;;
        pdf)                           echo "📕" ;;
        json|xml|yaml|yml|toml)        echo "📋" ;;
        c|cpp|h|java|go|rs)            echo "💻" ;;
        csv|tsv|xls|xlsx)              echo "📊" ;;
        db|sqlite|sql)                 echo "🗄 " ;;
        conf|cfg|ini|env)              echo "🔧" ;;
        *)                             echo "📄" ;;
    esac
}

# ──────────────────────────────────────────────
# Get human-readable file/dir size
# ──────────────────────────────────────────────
get_size() {
    local path="$1"
    if [ -d "$path" ]; then
        du -sh "$path" 2>/dev/null | cut -f1
    else
        stat -c %s "$path" 2>/dev/null | awk '{
            split("B KB MB GB TB", unit)
            size=$1
            for(i=1; size>=1024 && i<5; i++) size/=1024
            printf("%.1f%s", size, unit[i])
        }'
    fi
}

# ──────────────────────────────────────────────
# Selection helpers — keyed by item NAME.
# Fix: the original stored array *indices* in
# SELECTED. Indices go stale the moment items[]
# is reloaded (rename/delete/paste/refresh can
# all change sort order), so a later "delete
# selected" could silently hit the wrong files.
# Names are stable for the lifetime of a listing
# and selection is always cleared on directory
# change, so this is safe.
# ──────────────────────────────────────────────
is_selected() { [[ -n "${SELECTED_SET[$1]-}" ]]; }

toggle_selected() {
    if is_selected "$1"; then
        unset 'SELECTED_SET[$1]'
    else
        SELECTED_SET["$1"]=1
    fi
}

# ──────────────────────────────────────────────
# Terminal size + layout. Called every loop tick
# so resizes are picked up without relying on
# signal delivery interrupting `read` (portable).
# ──────────────────────────────────────────────
compute_header_lines() {
    if [ ${#CLIPBOARD[@]} -gt 0 ]; then HEADER_LINES=7; else HEADER_LINES=6; fi
}

compute_layout() {
    local l c
    l=$(tput lines 2>/dev/null); c=$(tput cols 2>/dev/null)
    [[ "$l" =~ ^[0-9]+$ ]] && TERM_LINES=$l
    [[ "$c" =~ ^[0-9]+$ ]] && TERM_COLS=$c

    compute_header_lines
    VISIBLE_ROWS=$(( TERM_LINES - HEADER_LINES - FOOTER_LINES ))
    (( VISIBLE_ROWS < 0 )) && VISIBLE_ROWS=0

    # Reserve room for " ▶ [✔] 🖼  " prefix (~8 cols) + 2 gap + 6-wide size col + margin.
    NAME_W=$(( TERM_COLS - 20 ))
    (( NAME_W < 8 )) && NAME_W=8

    # Fix 4: pin PROMPT_ROW to the true last terminal row (0-indexed).
    # Using HEADER_LINES+VISIBLE_ROWS+FOOTER_LINES would drift when HEADER_LINES
    # changes (clipboard line) and could land inside the file list on small
    # terminals. The last row is always TERM_LINES-1 regardless of layout.
    PROMPT_ROW=$(( TERM_LINES - 1 ))
    (( PROMPT_ROW < 0 )) && PROMPT_ROW=0
}

terminal_too_small() {
    (( TERM_COLS < MIN_COLS )) && return 0
    (( VISIBLE_ROWS < 1 )) && return 0
    return 1
}

show_too_small() {
    clear
    echo -e "${RED}Terminal window is too small.${NC}"
    echo -e "Please resize to at least ${WHITE}${MIN_COLS} columns${NC} and enough rows"
    echo -e "to show the header and menu (currently ${TERM_COLS}x${TERM_LINES})."
    echo -e "\n${DIM}[q] Quit${NC}"
}

# ──────────────────────────────────────────────
# Keep CURSOR and SCROLL_OFFSET valid for the
# current item count + visible window.
# ──────────────────────────────────────────────
clamp_view() {
    local total=${#items[@]}
    if (( total == 0 )); then
        CURSOR=0; SCROLL_OFFSET=0
        return
    fi
    (( CURSOR < 0 )) && CURSOR=0
    (( CURSOR >= total )) && CURSOR=$(( total - 1 ))

    (( VISIBLE_ROWS < 1 )) && return

    (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
    (( CURSOR < SCROLL_OFFSET )) && SCROLL_OFFSET=$CURSOR
    (( CURSOR >= SCROLL_OFFSET + VISIBLE_ROWS )) && SCROLL_OFFSET=$(( CURSOR - VISIBLE_ROWS + 1 ))

    local max_offset=$(( total - VISIBLE_ROWS ))
    (( max_offset < 0 )) && max_offset=0
    (( SCROLL_OFFSET > max_offset )) && SCROLL_OFFSET=$max_offset
}

# ──────────────────────────────────────────────
# Truncate/pad a name to exactly $2 display cols.
# Approximation: counts characters, not true
# terminal cell width, so wide CJK characters
# will under-truncate slightly (documented
# limitation, see final report).
# ──────────────────────────────────────────────
fit_text() {
    local text="$1" w="$2" len=${#1}
    if (( len <= w )); then
        printf '%-*s' "$w" "$text"
    elif (( w <= 1 )); then
        printf '%.*s' "$w" "$text"
    else
        printf '%s…' "${text:0:$((w-1))}"
    fi
}

# ──────────────────────────────────────────────
# Header — also records HEADER_LINES via
# compute_header_lines() so the printed line
# count and the value used for row math can
# never drift apart.
# ──────────────────────────────────────────────
show_header() {
    compute_header_lines
    # Move to the absolute top of the screen and erase everything so the
    # header always occupies exactly rows 0..(HEADER_LINES-1) regardless of
    # any previous output.  Using tput cup+ed instead of `clear` avoids the
    # momentary full-screen flash that `clear` causes on every refresh.
    tput cup 0 0
    tput ed 2>/dev/null || clear

    echo -ne "${CYAN}╔══════════════════════════════════════════════════════════╗\n"
    echo -ne "║            📂  TERMINAL FILE MANAGER                     ║\n"
    echo -ne "╚══════════════════════════════════════════════════════════╝${NC}\033[K\n"

    local path_w=$(( TERM_COLS - 12 )); (( path_w < 8 )) && path_w=8
    local shown_path="$CURRENT_DIR"
    if (( ${#shown_path} > path_w )); then
        shown_path="…${shown_path: -$((path_w-1))}"
    fi
    echo -ne " ${BLUE}📍 Path :${NC} ${WHITE}${shown_path}${NC}\033[K\n"

    local f d sz
    f=$(find "$CURRENT_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    d=$(find "$CURRENT_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    sz=$(du -sh "$CURRENT_DIR" 2>/dev/null | cut -f1)
    echo -ne " ${YELLOW}📊 Files: ${WHITE}$f  ${YELLOW}Folders: ${WHITE}$d  ${YELLOW}Size: ${WHITE}$sz${NC}\033[K\n"

    if [ ${#CLIPBOARD[@]} -gt 0 ]; then
        echo -ne " ${MAGENTA}📋 Clipboard [${CLIPBOARD_OP}]: ${#CLIPBOARD[@]} item(s) ready${NC}\033[K\n"
    fi

    echo -ne "${CYAN}──────────────────────────────────────────────────────────${NC}\033[K\n"
    # After printing all header lines the cursor is now exactly at row
    # HEADER_LINES, col 0 — ready for the item list.  No extra \n is emitted.
}

# ──────────────────────────────────────────────
# Render one item row (by item index). Reads
# size from SIZE_CACHE; never calls du/stat here.
# Name is fit to NAME_W so a long filename can
# never push later columns off-screen or wrap
# the line (the root cause of the row-addressing
# corruption — see final report).
# ──────────────────────────────────────────────
draw_item() {
    local i=$1
    local item="${items[$i]}"
    local full="$CURRENT_DIR/$item"
    local icon sel name_col size_col

    icon=$(get_icon "$item" "$full")
    local size="${SIZE_CACHE[$i]:-…}"

    sel=" "
    is_selected "$item" && sel="${GREEN}✔${NC}"

    name_col=$(fit_text "$item" "$NAME_W")
    size_col=$(printf '%6s' "$size")

    # Use echo -ne (no trailing newline) + explicit \033[K so the output
    # stays on a single terminal row even with emoji/wide chars.  The caller
    # (full_redraw / redraw_row) already moved the cursor to the correct
    # absolute row via tput cup before calling us.
    if [ "$i" -eq "$CURSOR" ]; then
        echo -ne " ${GREEN}▶ [${sel}] $icon ${WHITE}${name_col}  ${YELLOW}${size_col}${NC}\033[K"
    else
        echo -ne "   [$sel] $icon ${WHITE}${name_col}  ${DIM}${size_col}${NC}\033[K"
    fi
}

# ──────────────────────────────────────────────
# Partial update — jump to the exact screen row
# for item index $1 and repaint just that row.
# Screen row = HEADER_LINES + (index - SCROLL_OFFSET).
# No-ops if the index isn't currently visible
# (caller should force a full refresh instead
# when the visible window itself changes).
# ──────────────────────────────────────────────
redraw_row() {
    local i=$1
    (( i < SCROLL_OFFSET || i >= SCROLL_OFFSET + VISIBLE_ROWS )) && return
    (( i < 0 || i >= ${#items[@]} )) && return
    tput cup $(( HEADER_LINES + i - SCROLL_OFFSET )) 0
    tput el
    draw_item "$i"
    # draw_item uses echo -ne (no newline) so the cursor stays on this row;
    # no risk of the next caller landing on the wrong absolute row.
}

# ──────────────────────────────────────────────
# Key-binding footer. Line count MUST match
# FOOTER_LINES above (6 lines).
# ──────────────────────────────────────────────
show_keys() {
    # Caller (full_redraw) already positioned cursor at (HEADER_LINES+VISIBLE_ROWS, 0).
    # Use echo -ne for each line so output stays within the footer zone.
    echo -ne "${CYAN}──────────────────────────────────────────────────────────${NC}\033[K\n"
    echo -ne " ${GREEN}[↑↓] Move   [Enter] Open   [Bksp] Back   [Space] Select${NC}\033[K\n"
    echo -ne " ${GREEN}[c] Copy    [x] Cut   [v] Paste   [r] Rename   [d] Delete${NC}\033[K\n"
    echo -ne " ${GREEN}[/] Content Search   [n] Find by Name   [t] By Extension${NC}\033[K\n"
    echo -ne " ${GREEN}[k] Count Keyword    [s] Full Stats     [p] Path Info${NC}\033[K\n"

    local total=${#items[@]} info=""
    if (( total > VISIBLE_ROWS )); then
        local last=$(( SCROLL_OFFSET + VISIBLE_ROWS )); (( last > total )) && last=$total
        info="Showing $((SCROLL_OFFSET+1))-${last} of ${total}"
    elif (( total > 0 )); then
        info="${total} item(s)"
    fi
    echo -ne " ${GREEN}[q] Quit${NC}   ${DIM}${info}${NC}\033[K"
}

# ──────────────────────────────────────────────
# Full redraw: header + a windowed slice of
# items (only VISIBLE_ROWS of them, from
# SCROLL_OFFSET) + footer. Sizes are computed
# lazily, only for rows actually on screen, so
# opening a directory with thousands of files
# doesn't stall on stat'ing every single one
# up front.
# ──────────────────────────────────────────────
full_redraw() {
    # Always re-measure and re-clamp before rendering so a resize between
    # ticks never uses stale dimensions.
    compute_layout
    clamp_view

    show_header
    # show_header leaves the cursor at (HEADER_LINES, 0) via tput+echo flow.
    # We now use *absolute* tput cup positioning for every item row so that
    # no amount of line-wrap, emoji width, or terminal echo drift can shift
    # items away from their intended rows.  This is the same formula used
    # by redraw_row(), so both code-paths are guaranteed to agree.

    local total=${#items[@]}
    local row idx screen_row
    for ((row=0; row<VISIBLE_ROWS; row++)); do
        screen_row=$(( HEADER_LINES + row ))
        tput cup "$screen_row" 0
        tput el
        idx=$(( SCROLL_OFFSET + row ))
        if (( total == 0 && row == 0 )); then
            echo -ne "  ${DIM}(this folder is empty)${NC}\033[K"
        elif (( idx < total )); then
            if [ -z "${SIZE_CACHE[$idx]+x}" ]; then
                SIZE_CACHE[$idx]=$(get_size "$CURRENT_DIR/${items[$idx]}")
            fi
            draw_item "$idx"
        else
            echo -ne "\033[K"
        fi
    done

    # Position cursor at the footer start row and draw the key-help.
    tput cup $(( HEADER_LINES + VISIBLE_ROWS )) 0
    show_keys
}

# ──────────────────────────────────────────────
# Fixed-position prompt line, used for every
# read -p / confirmation in the app so answering
# a prompt never scrolls the file list or leaves
# a previous prompt's leftovers behind.
# ──────────────────────────────────────────────
prompt_input() {
    tput cnorm
    if (( PROMPT_ROW < TERM_LINES )); then
        tput cup "$PROMPT_ROW" 0
        # Fix 2: use tput el (erase to end of *line*) instead of tput ed
        # (erase to end of *screen*).  tput ed was wiping the entire footer
        # key-bindings area every time a prompt appeared.
        tput el 2>/dev/null
    else
        echo ""
    fi
    read -r -p "$1" PROMPT_REPLY
    tput civis
}

# Same fixed line, for a transient (non-interactive) status message.
# The sleep is a deliberate "let the user read this" pause, not a
# rendering hack — but while it's not actively read()ing, the tty's
# own local echo would otherwise print any keys typed in the meantime
# as stray raw text. Echo (not canonical mode/line editing — only
# echo) is suppressed just for that window and restored immediately
# after, so type-ahead is silently buffered instead of flashing on
# screen, and normal read -p prompts elsewhere are unaffected.
flash_message() {
    tput cnorm
    if (( PROMPT_ROW < TERM_LINES )); then
        tput cup "$PROMPT_ROW" 0
        # Fix 3a: erase only this one line (tput el) not the whole screen below
        # (tput ed) so the footer key-bindings are never destroyed.
        tput el 2>/dev/null
        echo -e "  $1"
    else
        echo -e "\n  $1"
    fi
    local _fm_stty; _fm_stty=$(stty -g 2>/dev/null)
    stty -echo 2>/dev/null
    sleep 1
    [ -n "$_fm_stty" ] && stty "$_fm_stty" 2>/dev/null
    # Fix 3b: blank the flash row after the pause so the old message text
    # does not linger on screen until the next full_redraw.
    if (( PROMPT_ROW < TERM_LINES )); then
        tput cup "$PROMPT_ROW" 0
        tput el 2>/dev/null
    fi
    tput civis
}

# ──────────────────────────────────────────────
# open text file in a GUI editor
# ──────────────────────────────────────────────
open_text_file() {
    local file="$1"

    if command -v xdg-open &>/dev/null; then
        xdg-open "$file" >/dev/null 2>&1 &
    elif command -v gedit &>/dev/null; then
        gedit "$file" >/dev/null 2>&1 &
    elif command -v kate &>/dev/null; then
        kate "$file" >/dev/null 2>&1 &
    elif command -v mousepad &>/dev/null; then
        mousepad "$file" >/dev/null 2>&1 &
    elif command -v pluma &>/dev/null; then
        pluma "$file" >/dev/null 2>&1 &
    elif command -v xed &>/dev/null; then
        xed "$file" >/dev/null 2>&1 &
    elif command -v leafpad &>/dev/null; then
        leafpad "$file" >/dev/null 2>&1 &
    elif command -v nano &>/dev/null; then
        nano "$file"          # TUI — blocks until user exits
    else
        less -R "$file"       # absolute last resort
    fi
}

# ══════════════════════════════════════════════
#                 MAIN LOOP
# ══════════════════════════════════════════════
file_manager() {
    tput civis  # hide terminal cursor
    local prev_lines=-1 prev_cols=-1

    while true; do

        # --- reload listing only when directory has changed ──
        if [ "$NEED_RELOAD" -eq 1 ]; then
            mapfile -t items < <(ls -1A "$CURRENT_DIR" 2>/dev/null | sort) || items=()
            SIZE_CACHE=()
            # A raw numeric CURSOR is only valid until the next sort order
            # changes (rename moves a file alphabetically, a paste adds
            # entries, etc.) — re-find the item by name when a handler
            # asked us to, instead of silently landing on whatever now
            # occupies that slot.
            if [ -n "$PENDING_ANCHOR" ]; then
                local _idx
                for _idx in "${!items[@]}"; do
                    if [ "${items[$_idx]}" = "$PENDING_ANCHOR" ]; then
                        CURSOR=$_idx
                        break
                    fi
                done
                PENDING_ANCHOR=""
            fi
            NEED_RELOAD=0
        fi

        # --- recompute layout every tick so resizes are caught
        #     even though we can't rely on a signal interrupting read ---
        compute_layout
        if (( TERM_LINES != prev_lines || TERM_COLS != prev_cols )); then
            NEED_REFRESH=1
            prev_lines=$TERM_LINES; prev_cols=$TERM_COLS
        fi
        clamp_view

        if terminal_too_small; then
            show_too_small
            IFS= read -rsn1 -t 0.5 key
            [[ "$key" == "q" ]] && { tput cnorm; clear; exit 0; }
            NEED_REFRESH=1   # re-check size/redraw once it's big enough again
            continue
        fi

        if [ "$NEED_REFRESH" -eq 1 ]; then
            full_redraw
            NEED_REFRESH=0
            PREV_CURSOR=$CURSOR
        fi

        # ── Read one keypress (timed, so we keep polling for resize) ──
        unset key
        IFS= read -rsn1 -t 0.5 key
        rc=$?
        (( rc != 0 )) && continue   # timeout / no input this tick

        # ── Arrow / escape key handling ──────────────────────────────
        # We received \x1b. Now determine whether it is:
        #   a) A CSI sequence  \x1b [ <final>   (e.g. cursor keys)
        #   b) An SS3 sequence \x1b O <final>   (alternate cursor keys)
        #   c) A bare Escape keypress (no follow-up bytes)
        #
        # Strategy: switch the tty to non-canonical / no-echo mode for a
        # brief window so we can read the following bytes without the tty
        # driver ever echoing them.  This is the only race-free approach
        # when running inside a PTY (WSL, tmux, SSH, etc.).
        if [[ $key == $'\x1b' ]]; then
            local esc1 esc2 _drain
            local _stty_save; _stty_save=$(stty -g 2>/dev/null)
            stty -icanon -echo min 0 time 1 2>/dev/null   # 0.1 s timeout
            IFS= read -rsn1 esc1 2>/dev/null              # '[' or 'O' or empty
            if [[ $esc1 == '[' || $esc1 == 'O' ]]; then
                IFS= read -rsn1 esc2 2>/dev/null          # A/B/C/D or digit
                # For extended sequences like \x1b[1;2A read until non-digit/non-semicolon
                while [[ $esc2 == [0-9] || $esc2 == ';' ]]; do
                    IFS= read -rsn1 _drain 2>/dev/null
                    esc2="$_drain"   # only keep the final byte for matching
                done
            fi
            [ -n "$_stty_save" ] && stty "$_stty_save" 2>/dev/null

            local esc="${esc1}${esc2}"
            case "$esc" in
                "[A"|"OA")   # Up
                    if (( CURSOR > 0 )); then
                        PREV_CURSOR=$CURSOR
                        (( CURSOR-- ))
                        local old_offset=$SCROLL_OFFSET
                        clamp_view
                        if (( SCROLL_OFFSET != old_offset )); then
                            NEED_REFRESH=1
                        else
                            redraw_row "$PREV_CURSOR"
                            redraw_row "$CURSOR"
                        fi
                    fi
                    ;;
                "[B"|"OB")   # Down
                    if (( CURSOR < ${#items[@]} - 1 )); then
                        PREV_CURSOR=$CURSOR
                        (( CURSOR++ ))
                        local old_offset=$SCROLL_OFFSET
                        clamp_view
                        if (( SCROLL_OFFSET != old_offset )); then
                            NEED_REFRESH=1
                        else
                            redraw_row "$PREV_CURSOR"
                            redraw_row "$CURSOR"
                        fi
                    fi
                    ;;
                # bare ESC (esc1 empty) — ignore silently
            esac
            continue   # skip the case "$key" block below
        fi

        # ── Resolve current item ──
        local selected_item="" full_path=""
        if [ ${#items[@]} -gt 0 ]; then
            selected_item="${items[$CURSOR]}"
            full_path="$CURRENT_DIR/$selected_item"
        fi

        # ── Key actions ──
        case "$key" in

        # ── ENTER: open folder or file ──
        "")
            [ -z "$full_path" ] && continue

            if [ -d "$full_path" ]; then
                CURRENT_DIR="$full_path"
                CURSOR=0
                PREV_CURSOR=-1
                SELECTED_SET=()
                NEED_RELOAD=1
                NEED_REFRESH=1

            elif [ -f "$full_path" ]; then
                tput cnorm
                local mime
                mime=$(file --mime-type -b "$full_path")

                case "$mime" in
                    text/*)
                        open_text_file "$full_path"
                        ;;
                    image/*)
                        if command -v xdg-open &>/dev/null; then
                            xdg-open "$full_path" >/dev/null 2>&1 &
                        elif command -v feh &>/dev/null; then
                            feh "$full_path" &
                        else
                            flash_message "${YELLOW}⚠ No image viewer available.${NC}"
                        fi
                        ;;
                    application/pdf)
                        if command -v xdg-open &>/dev/null; then
                            xdg-open "$full_path" >/dev/null 2>&1 &
                        elif command -v evince &>/dev/null; then
                            evince "$full_path" &
                        else
                            flash_message "${YELLOW}⚠ No PDF viewer available.${NC}"
                        fi
                        ;;
                    *)
                        if command -v xdg-open &>/dev/null; then
                            xdg-open "$full_path" >/dev/null 2>&1 &
                        else
                            flash_message "${YELLOW}⚠ Cannot open: $mime${NC}"
                        fi
                        ;;
                esac

                tput civis
                NEED_REFRESH=1
            else
                flash_message "${RED}❌ No longer exists: $selected_item${NC}"
                NEED_RELOAD=1
                NEED_REFRESH=1
            fi
            ;;

        # ── BACKSPACE: go up one level, cursor stays at top ──
        $'\x7f'|$'\x08')
            if [ "$CURRENT_DIR" != "$HOME" ]; then
                local parent
                parent=$(dirname "$CURRENT_DIR")
                [ -n "$parent" ] && [ -d "$parent" ] && CURRENT_DIR="$parent"
            fi
            CURSOR=0
            PREV_CURSOR=-1
            SELECTED_SET=()
            NEED_RELOAD=1
            NEED_REFRESH=1
            ;;

        # ── SPACE: toggle selection, partial redraw only ──
        " ")
            [ -z "$full_path" ] && continue
            toggle_selected "$selected_item"
            redraw_row "$CURSOR"
            ;;

        # ── c: COPY ──
        "c")
            [ -z "$full_path" ] && continue
            CLIPBOARD=()
            if [ ${#SELECTED_SET[@]} -gt 0 ]; then
                for name in "${!SELECTED_SET[@]}"; do
                    CLIPBOARD+=("$CURRENT_DIR/$name")
                done
            else
                CLIPBOARD=("$full_path")
            fi
            CLIPBOARD_OP="COPY"
            flash_message "${GREEN}✅ Copied ${#CLIPBOARD[@]} item(s) to clipboard${NC}"
            NEED_REFRESH=1   # header grows/shrinks by a line for the clipboard status
            ;;

        # ── x: CUT (move) ──
        "x")
            [ -z "$full_path" ] && continue
            CLIPBOARD=()
            if [ ${#SELECTED_SET[@]} -gt 0 ]; then
                for name in "${!SELECTED_SET[@]}"; do
                    CLIPBOARD+=("$CURRENT_DIR/$name")
                done
            else
                CLIPBOARD=("$full_path")
            fi
            CLIPBOARD_OP="CUT"
            flash_message "${GREEN}✅ Cut ${#CLIPBOARD[@]} item(s) — 'v' elsewhere to move${NC}"
            NEED_REFRESH=1
            ;;

        # ── v: PASTE (copy or move, depending on CLIPBOARD_OP) ──
        "v")
            if [ ${#CLIPBOARD[@]} -eq 0 ]; then
                flash_message "${RED}❌ Clipboard is empty!${NC}"
            else
                tput cnorm
                local src base dest err ok=0 fail=0 skip=0
                for src in "${CLIPBOARD[@]}"; do
                    if [ ! -e "$src" ]; then
                        flash_message "${YELLOW}⚠ Source no longer exists: $(basename -- "$src")${NC}"
                        ((skip++)); continue
                    fi
                    base=$(basename -- "$src")
                    dest="$CURRENT_DIR/$base"

                    if [ "$src" = "$dest" ]; then
                        ((skip++)); continue   # pasting into its own location
                    fi

                    if [ -e "$dest" ]; then
                        prompt_input "  ⚠ '$base' exists in destination. Overwrite? [y/N]: "
                        if [[ ! "$PROMPT_REPLY" =~ ^[yY]$ ]]; then
                            ((skip++)); continue
                        fi
                        rm -rf -- "$dest" 2>/dev/null
                    fi

                    if [ "$CLIPBOARD_OP" = "CUT" ]; then
                        # Fix 6/7: `2>&1 1>/dev/null` sends stderr to the
                        # original stdout and then redirects stdout to /dev/null.
                        # Inside a command substitution the "original stdout" IS
                        # the pipe, so err ends up empty on error.  The correct
                        # idiom to capture only stderr is `2>&1 >/dev/null`.
                        if err=$(mv -- "$src" "$dest" 2>&1 >/dev/null); then ((ok++)); else ((fail++)); fi
                    else
                        if err=$(cp -r -- "$src" "$dest" 2>&1 >/dev/null); then ((ok++)); else ((fail++)); fi
                    fi
                done

                local verb="Copied"; [ "$CLIPBOARD_OP" = "CUT" ] && verb="Moved"
                local summary="${GREEN}✅ ${verb} ${ok}${NC}"
                (( skip > 0 )) && summary+="  ${DIM}(${skip} skipped)${NC}"
                (( fail > 0 )) && summary+="  ${RED}(${fail} failed: ${err})${NC}"
                flash_message "$summary"

                [ "$CLIPBOARD_OP" = "CUT" ] && { CLIPBOARD=(); CLIPBOARD_OP=""; }
                PENDING_ANCHOR="$selected_item"   # keep the cursor on whatever was highlighted
                tput civis
                NEED_RELOAD=1
                NEED_REFRESH=1
            fi
            ;;

        # ── r: RENAME ──
        "r")
            [ -z "$full_path" ] && continue
            prompt_input "  Rename '${selected_item}' → "
            local newname="$PROMPT_REPLY"
            if [ -n "$newname" ]; then
                if [[ "$newname" == */* ]]; then
                    flash_message "${RED}❌ Name cannot contain '/'${NC}"
                elif [ -e "$CURRENT_DIR/$newname" ]; then
                    flash_message "${RED}❌ '$newname' already exists!${NC}"
                else
                    local err
                    if err=$(mv -- "$full_path" "$CURRENT_DIR/$newname" 2>&1 >/dev/null); then
                        flash_message "${GREEN}✅ Renamed to: $newname${NC}"
                        SELECTED_SET=()
                        PENDING_ANCHOR="$newname"      # follow the file under its new name
                    else
                        flash_message "${RED}❌ Rename failed: ${err}${NC}"
                        PENDING_ANCHOR="$selected_item" # unchanged; stay put
                    fi
                    NEED_RELOAD=1
                fi
            fi
            NEED_REFRESH=1
            ;;

        # ── d: DELETE single or multiple selected ──
        "d")
            if [ ${#SELECTED_SET[@]} -gt 0 ]; then
                prompt_input "  ⚠ Delete ${#SELECTED_SET[@]} selected item(s)? [y/N]: "
                if [[ "$PROMPT_REPLY" =~ ^[yY]$ ]]; then
                    local name target fail=0
                    for name in "${!SELECTED_SET[@]}"; do
                        target="$CURRENT_DIR/$name"
                        if [ -e "$target" ] && [ "$target" != "/" ]; then
                            rm -rf -- "$target" 2>/dev/null || ((fail++))
                        fi
                    done
                    local msg="${RED}🗑 Deleted ${#SELECTED_SET[@]} item(s)${NC}"
                    (( fail > 0 )) && msg="${RED}🗑 Deleted with ${fail} error(s) (check permissions)${NC}"
                    flash_message "$msg"
                    SELECTED_SET=()
                    CURSOR=0
                    NEED_RELOAD=1
                fi
            else
                [ -z "$full_path" ] && continue
                prompt_input "  ⚠ Delete '${selected_item}'? [y/N]: "
                if [[ "$PROMPT_REPLY" =~ ^[yY]$ ]]; then
                    local err
                    if [ -e "$full_path" ] && [ "$full_path" != "/" ]; then
                        # Fix 8: same error-capture fix as mv/cp above.
                        if err=$(rm -rf -- "$full_path" 2>&1 >/dev/null); then
                            flash_message "${RED}🗑 Deleted: $selected_item${NC}"
                        else
                            flash_message "${RED}❌ Delete failed: ${err}${NC}"
                        fi
                    fi
                    # Fix 9: after reload, items[] will have one fewer entry.
                    # Decrement CURSOR now so clamp_view() in the next tick
                    # lands on the item just above the deleted one (or 0 if
                    # the deleted item was the first).  We can't know the new
                    # total until after the reload, so let clamp_view() do the
                    # final bound-check — just ensure CURSOR doesn't stay
                    # pointing past the end.
                    (( CURSOR > 0 )) && (( CURSOR-- ))
                    NEED_RELOAD=1
                fi
            fi
            NEED_REFRESH=1
            ;;

        # ── /: SEARCH file contents ──
        "/")
            prompt_input "  🔍 Keyword to search in files: "
            local kw="$PROMPT_REPLY"
            if [ -n "$kw" ]; then
                clear
                echo -e "${CYAN}  Searching for '${kw}' in:${NC}"
                echo -e "  ${WHITE}$CURRENT_DIR${NC}\n"
                local results cap=$(( TERM_LINES > 12 ? TERM_LINES - 8 : 4 ))
                results=$(grep -rin "$kw" "$CURRENT_DIR" 2>/dev/null)
                if [ -z "$results" ]; then
                    echo -e "  ${RED}❌ No matches found.${NC}"
                else
                    local count; count=$(echo "$results" | wc -l)
                    echo -e "  ${GREEN}✅ $count match(es):${NC}\n"
                    echo "$results" | head -n "$cap"
                    (( count > cap )) && echo -e "  ${DIM}… $(( count - cap )) more not shown${NC}"
                fi
                read -rsp $'\nPress Enter to continue...' _
            fi
            NEED_REFRESH=1
            ;;

        # ── n: FIND by name ──
        "n")
            prompt_input "  📁 Find file/folder by name: "
            local fname="$PROMPT_REPLY"
            if [ -n "$fname" ]; then
                clear
                echo -e "${CYAN}  Finding '${fname}' in:${NC}"
                echo -e "  ${WHITE}$CURRENT_DIR${NC}\n"
                local results cap=$(( TERM_LINES > 12 ? TERM_LINES - 8 : 4 ))
                results=$(find "$CURRENT_DIR" -iname "*$fname*" 2>/dev/null)
                if [ -z "$results" ]; then
                    echo -e "  ${RED}❌ Nothing found.${NC}"
                else
                    local count; count=$(echo "$results" | wc -l)
                    echo -e "  ${GREEN}✅ $count result(s):${NC}\n"
                    echo "$results" | head -n "$cap"
                    (( count > cap )) && echo -e "  ${DIM}… $(( count - cap )) more not shown${NC}"
                fi
                read -rsp $'\nPress Enter to continue...' _
            fi
            NEED_REFRESH=1
            ;;

        # ── t: FIND by extension ──
        "t")
            prompt_input "  🔎 Find by extension (e.g. txt, py, sh): "
            local fext="$PROMPT_REPLY"
            if [ -n "$fext" ]; then
                clear
                echo -e "${CYAN}  Finding all .${fext} files in:${NC}"
                echo -e "  ${WHITE}$CURRENT_DIR${NC}\n"
                local results cap=$(( TERM_LINES > 12 ? TERM_LINES - 8 : 4 ))
                results=$(find "$CURRENT_DIR" -type f \( -iname "*.$fext" -o -iname "$fext" \) 2>/dev/null)
                if [ -z "$results" ]; then
                    echo -e "  ${RED}❌ No .${fext} files found.${NC}"
                else
                    local count; count=$(echo "$results" | wc -l)
                    echo -e "  ${GREEN}✅ $count file(s):${NC}\n"
                    echo "$results" | head -n "$cap"
                    (( count > cap )) && echo -e "  ${DIM}… $(( count - cap )) more not shown${NC}"
                fi
                read -rsp $'\nPress Enter to continue...' _
            fi
            NEED_REFRESH=1
            ;;

        # ── k: COUNT keyword occurrences ──
        "k")
            prompt_input "  🔢 Count keyword in all files: "
            local kw="$PROMPT_REPLY"
            if [ -n "$kw" ]; then
                clear
                echo -e "${CYAN}  Counting '${kw}' in:${NC}"
                echo -e "  ${WHITE}$CURRENT_DIR${NC}\n"
                local count file_count
                count=$(grep -roi "$kw" "$CURRENT_DIR" 2>/dev/null | wc -l)
                file_count=$(grep -ril "$kw" "$CURRENT_DIR" 2>/dev/null | wc -l)
                echo -e "  ${GREEN}✅ '${kw}' appears ${WHITE}${count}${GREEN} time(s) across ${WHITE}${file_count}${GREEN} file(s)${NC}"
                read -rsp $'\nPress Enter to continue...' _
            fi
            NEED_REFRESH=1
            ;;

        # ── s: FULL folder statistics ──
        "s")
            clear
            echo -e "${CYAN}╔══════════════════════════════════════════════╗"
            echo -e "║            📊 FOLDER STATISTICS              ║"
            echo -e "╚══════════════════════════════════════════════╝${NC}"
            echo -e "  ${BLUE}Path: ${WHITE}$CURRENT_DIR${NC}\n"

            local total_files total_dirs fsz hidden subdirs
            total_files=$(find "$CURRENT_DIR" -type f 2>/dev/null | wc -l)
            total_dirs=$(find "$CURRENT_DIR" -type d 2>/dev/null | wc -l)
            fsz=$(du -sh --max-depth=0 "$CURRENT_DIR" 2>/dev/null | cut -f1)
            hidden=$(find "$CURRENT_DIR" -maxdepth 1 -mindepth 1 -name ".*" 2>/dev/null | wc -l)

            echo -e "  ${YELLOW}Total Files:      ${WHITE}$total_files${NC}"
            subdirs=$(( total_dirs > 0 ? total_dirs - 1 : 0 ))
            echo -e "  ${YELLOW}Total Subfolders: ${WHITE}$subdirs${NC}"
            echo -e "  ${YELLOW}Total Size:       ${WHITE}$fsz${NC}"
            echo -e "  ${YELLOW}Hidden items:     ${WHITE}$hidden${NC}"

            echo -e "\n  ${CYAN}── Top 10 file types: ──${NC}"
            find "$CURRENT_DIR" -type f 2>/dev/null \
                | sed 's/.*\.//' \
                | sort | uniq -c | sort -rn | head -10 \
                | while read -r cnt fext2; do
                    echo -e "    ${GREEN}.${fext2}${NC}  →  $cnt file(s)"
                  done

            echo -e "\n  ${CYAN}── Largest items here: ──${NC}"
            if compgen -G "$CURRENT_DIR/*" "$CURRENT_DIR/.*" > /dev/null 2>&1; then
                du -sh "$CURRENT_DIR"/* 2>/dev/null | sort -rh | head -5 \
                    | while read -r dsz path; do
                        echo -e "    ${WHITE}$(basename "$path")${NC}  ${YELLOW}$dsz${NC}"
                      done
            else
                echo -e "    ${DIM}(no items)${NC}"
            fi

            read -rsp $'\nPress Enter to continue...' _
            NEED_REFRESH=1
            ;;

        # ── p: PATH info ──
        "p")
            clear
            echo -e "${CYAN}╔══════════════════════════════════════════════╗"
            echo -e "║               📍 PATH INFO                   ║"
            echo -e "╚══════════════════════════════════════════════╝${NC}"
            echo -e "\n  ${YELLOW}Current folder:${NC}"
            echo -e "  ${WHITE}$CURRENT_DIR${NC}"
            if [ -n "$selected_item" ]; then
                echo -e "\n  ${YELLOW}Selected item:${NC}"
                echo -e "  ${WHITE}$full_path${NC}"
            fi

            if command -v xclip &>/dev/null; then
                echo "$CURRENT_DIR" | xclip -selection clipboard
                echo -e "\n  ${GREEN}✅ Path copied to clipboard (xclip)${NC}"
            elif command -v xsel &>/dev/null; then
                echo "$CURRENT_DIR" | xsel --clipboard --input
                echo -e "\n  ${GREEN}✅ Path copied to clipboard (xsel)${NC}"
            elif command -v pbcopy &>/dev/null; then
                echo "$CURRENT_DIR" | pbcopy
                echo -e "\n  ${GREEN}✅ Path copied to clipboard (macOS)${NC}"
            else
                echo -e "\n  ${DIM}(Install xclip to enable auto clipboard copy)${NC}"
            fi

            read -rsp $'\nPress Enter to continue...' _
            NEED_REFRESH=1
            ;;

        # ── q: QUIT ──
        "q")
            tput cnorm
            clear
            echo -e "  ${GREEN}👋 Goodbye!${NC}\n"
            exit 0
            ;;

        esac
    done
}

# ── Entry point ──
file_manager
