#!/usr/bin/env bash
# process_manager_pro.sh - Process Manager Pro (TUI) using dialog
# Integrates advanced features: ASCII graphs, nice/renice, service manager,
# zombie detector, sensors (cpu temps), network speed monitor,
# disk I/O monitor (iostat), fuzzy-kill (fzf), high-CPU alert, HTML report.
#
# Tested on Ubuntu (VirtualBox). Requires: dialog; optional: lm-sensors, sysstat, fzf
set -euo pipefail

# ---- temp files & cleanup ----
TMPDIR=$(mktemp -d 2>/dev/null || echo "/tmp/pmpro.$$")
PROCLIST="$TMPDIR/proclist.txt"
MENU_PIDS="$TMPDIR/menu_pids.txt"
TMPGRAPH="$TMPDIR/graph.txt"
LOGFILE="$HOME/.process_manager_pro.log"
REPORTDIR="$HOME/process_manager_reports"
MONITOR_PIDFILE="$TMPDIR/monitor.pid"

cleanup() {
  [ -n "${MON_PID:-}" ] 2>/dev/null && kill "${MON_PID}" 2>/dev/null || true
  [ -f "$MONITOR_PIDFILE" ] && kill "$(cat "$MONITOR_PIDFILE")" 2>/dev/null || true
  rm -rf "$TMPDIR"
  clear
}
trap cleanup EXIT

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

ensure_logfile() {
  if [ ! -f "$LOGFILE" ]; then
    echo "# Process Manager Pro log - created $(timestamp)" > "$LOGFILE"
    chmod 600 "$LOGFILE"
  fi
}

# ---- helper to show msgbox ----
msg() { dialog --msgbox "$1" 12 60; }

# ---- Main menu ----
main_menu() {
  while true; do
    CHOICE=$(dialog --clear --stdout --title "Process Manager Pro" \
      --menu "Choose an option" 20 80 14 \
      1 "View processes (sorted)" \
      2 "Search process by name" \
      3 "Kill a process (menu / fuzzy)" \
      4 "Process priority (nice/renice)" \
      5 "Top snapshot (one-shot)" \
      6 "System load & memory" \
      7 "Live Monitor (tail)" \
      8 "Live ASCII CPU/RAM Graph" \
      9 "Network Speed Monitor (live)" \
      10 "Disk I/O Monitor (iostat)" \
      11 "Service Manager (systemctl)" \
      12 "Zombie Process Detector" \
      13 "CPU Temp / Sensors" \
      14 "High-CPU Alert Settings" \
      15 "Export System Report (HTML/MD)" \
      16 "View kill-log (~/.process_manager_pro.log)" \
      17 "Help / About" \
      18 "Exit")
    case "$CHOICE" in
      1) view_processes ;;
      2) search_process ;;
      3) kill_process ;;
      4) priority_manager ;;
      5) top_snapshot ;;
      6) show_load ;;
      7) live_tail_monitor ;;
      8) ascii_graph ;;
      9) network_speed_monitor ;;
      10) disk_io_monitor ;;
      11) service_manager ;;
      12) zombie_detector ;;
      13) cpu_sensors ;;
      14) high_cpu_alert_menu ;;
      15) export_report ;;
      16) show_log ;;
      17) show_help ;;
      18) break ;;
      *) break ;;
    esac
  done
}

# ---- feature: view processes ----
view_processes() {
  SORT=$(dialog --clear --stdout --title "Sort processes" \
    --menu "Sort by:" 10 50 4 \
    1 "CPU (desc)" \
    2 "Memory (desc)" \
    3 "PID (asc)" \
    4 "User")
  case "$SORT" in
    1) ps aux --sort=-%cpu > "$PROCLIST" ;;
    2) ps aux --sort=-%mem > "$PROCLIST" ;;
    3) ps aux --sort=pid > "$PROCLIST" ;;
    4) ps aux --sort=user > "$PROCLIST" ;;
    *) ps aux > "$PROCLIST" ;;
  esac
  dialog --title "Process List (press OK to return)" --textbox "$PROCLIST" 30 100
}

# ---- feature: search process ----
search_process() {
  pname=$(dialog --stdout --inputbox "Enter process name (or substring):" 8 60) || return
  [ -z "$pname" ] && return
  ps aux | grep -i -- "$pname" | grep -v grep > "$PROCLIST" || true
  if [ ! -s "$PROCLIST" ]; then
    dialog --msgbox "No processes matching: $pname" 6 50
  else
    dialog --textbox "$PROCLIST" 20 100
  fi
}

# ---- helper: build PID menu entries ----
build_pid_menu() {
  # produce lines: PID "user — cmd (%cpu %mem)"
  ps aux --sort=-%cpu | awk 'NR>1{cmd=""; for(i=11;i<=NF;i++){cmd=cmd" "$i}; printf "%s \"%s — %s %s%%cpu %s%%mem\"\n",$2,$1,cmd,$3,$4}' > "$MENU_PIDS" || true
  head -n 50 "$MENU_PIDS" > "$TMPDIR/menu_head.txt"
}

# ---- feature: kill process (menu + fuzzy fallback) ----
kill_process() {
  build_pid_menu
  # try fuzzy selection if fzf exists and user chooses fuzzy
  if command -v fzf >/dev/null 2>&1; then
    MODE=$(dialog --stdout --menu "Kill mode" 10 40 2 1 "Menu select" 2 "Fuzzy select (fzf)") || return
  else
    MODE=1
  fi

  if [ "$MODE" -eq 2 ]; then
    # export list to temp then open fzf in terminal; need to open a sub-terminal using dialog --editbox as workaround
    tmpfzf="$TMPDIR/fzflist.txt"
    awk '{print $0}' "$MENU_PIDS" > "$tmpfzf"
    # Use dialog --textbox to instruct user to press Enter on desired PID in next terminal (we'll spawn fzf in xterm if available)
    if command -v xterm >/dev/null 2>&1; then
      dialog --msgbox "fzf will open in a new xterm window. Select a line and press Enter to pick the PID." 8 60
      xterm -e "cut -d ' ' -f1 $tmpfzf | paste -d ' ' - $tmpfzf | nl -ba -v0 | sed 's/^/ /' | fzf --no-sort --ansi --height=40" &
      # Wait a short while - fallback to menu if xterm not available or user closes it
      sleep 2
      dialog --msgbox "If xterm/fzf did not open, you will be shown the menu fallback." 6 60
    else
      dialog --msgbox "fzf installed but no xterm found; falling back to menu selection." 6 60
      MODE=1
    fi
  fi

  if [ "$MODE" -eq 1 ]; then
    if [ ! -s "$TMPDIR/menu_head.txt" ]; then
      dialog --msgbox "No processes found." 6 40
      return
    fi
    PID_MENU=$(dialog --clear --stdout --title "Select process to kill (top 50)" \
      --menu "Choose one (or Cancel to enter PID manually)" 22 100 50 \
      $(xargs < "$TMPDIR/menu_head.txt")) || PID_MENU=""
    if [ -n "$PID_MENU" ]; then
      PID="$PID_MENU"
    else
      PID=$(dialog --stdout --inputbox "Enter PID to kill (numeric):" 8 50) || return
    fi
  else
    # fallback: ask for PID
    PID=$(dialog --stdout --inputbox "Enter PID manually (fzf fallback):" 8 50) || return
  fi

  [ -z "${PID:-}" ] && return

  PROCINFO=$(ps -p "$PID" -o pid,user,%cpu,%mem,cmd --no-headers 2>/dev/null || echo "not found")
  confirm=$(dialog --stdout --title "Confirm" --yesno "Send SIGTERM to PID $PID ?\n\n$PROCINFO" 10 70; echo $?)
  if [ "$confirm" -eq 0 ]; then
    if kill "$PID" 2>/dev/null; then
      dialog --msgbox "PID $PID: SIGTERM sent successfully." 6 50
      ensure_logfile
      echo "$(timestamp) | PID:$PID | SIGTERM | BEFORE: $PROCINFO" >> "$LOGFILE"
    else
      dialog --yesno "Failed to kill PID $PID. Try with sudo?" 8 60
      if [ $? -eq 0 ]; then
        if sudo kill "$PID" 2>/dev/null; then
          dialog --msgbox "PID $PID killed with sudo." 6 50
          ensure_logfile
          echo "$(timestamp) | PID:$PID | SIGTERM(sudo) | BEFORE: $PROCINFO" >> "$LOGFILE"
        else
          dialog --msgbox "Still failed. PID may not exist or permission denied." 6 50
          ensure_logfile
          echo "$(timestamp) | PID:$PID | KILL_FAILED | BEFORE: $PROCINFO" >> "$LOGFILE"
        fi
      fi
    fi
  else
    dialog --msgbox "Cancelled." 6 30
  fi
}

# ---- feature: priority manager (nice/renice) ----
priority_manager() {
  build_pid_menu
  PID=$(dialog --stdout --inputbox "Enter PID to change priority (or leave blank to pick from top list):" 8 60) || return
  if [ -z "$PID" ]; then
    PID=$(dialog --clear --stdout --title "Select PID to renice" \
      --menu "Pick one" 20 80 20 $(xargs < "$TMPDIR/menu_head.txt")) || return
  fi
  CUR=$(ps -p "$PID" -o pid,ni,cmd --no-headers 2>/dev/null || true)
  if [ -z "$CUR" ]; then
    dialog --msgbox "PID $PID not found." 6 40
    return
  fi
  NEW=$(dialog --stdout --inputbox "Current: $CUR\nEnter new nice value (-20..19):" 10 60) || return
  if [ -z "$NEW" ]; then return; fi
  if ! [[ "$NEW" =~ ^-?[0-9]+$ ]]; then dialog --msgbox "Invalid value." 6 40; return; fi
  if renice "$NEW" -p "$PID" >/dev/null 2>&1; then
    dialog --msgbox "Renice success for PID $PID to $NEW." 6 50
    ensure_logfile
    echo "$(timestamp) | PID:$PID | RENICE:$NEW" >> "$LOGFILE"
  else
    # try with sudo
    dialog --yesno "Renice failed (permission?). Try with sudo?" 8 60
    if [ $? -eq 0 ]; then
      if sudo renice "$NEW" -p "$PID" >/dev/null 2>&1; then
        dialog --msgbox "Renice (sudo) success for PID $PID to $NEW." 6 50
        ensure_logfile
        echo "$(timestamp) | PID:$PID | RENICE(sudo):$NEW" >> "$LOGFILE"
      else
        dialog --msgbox "Renice still failed." 6 40
      fi
    fi
  fi
}

# ---- feature: one-shot top snapshot ----
top_snapshot() {
  top -b -n1 > "$PROCLIST"
  dialog --title "top snapshot (one-shot)" --textbox "$PROCLIST" 30 110
}

# ---- feature: system load & memory ----
show_load() {
  {
    uptime
    echo
    echo "Free / Mem info:"
    free -h
  } > "$PROCLIST"
  dialog --title "System load & memory" --textbox "$PROCLIST" 14 70
}

# ---- feature: live tail monitor (ps + top) ----
live_tail_monitor() {
  # update loop writes snapshot then sleep; user cancels tailbox to stop
  while true; do
    {
      printf "Live snapshot: %s\n\n" "$(timestamp)"
      top -b -n1 | head -n 30
      echo
      echo "ps aux (top 20 by CPU):"
      ps aux --sort=-%cpu | head -n 21
    } > "$PROCLIST"
    sleep 2
  done &
  MON_PID=$!
  echo "$MON_PID" > "$MONITOR_PIDFILE"
  dialog --title "Live Monitor - press Cancel to stop" --tailbox "$PROCLIST" 30 110 || true
  kill "$MON_PID" 2>/dev/null || true
  rm -f "$MONITOR_PIDFILE" || true
}

# ---- feature 1 (ASCII CPU/RAM graph) ----
ascii_graph() {
  # simple history arrays
  local hist_len=40
  local -a cpu_hist mem_hist
  for i in $(seq 1 $hist_len); do cpu_hist[i]=0; mem_hist[i]=0; done

  # updater loop writes a text graph
  while true; do
    # read usage
    # CPU: use top -bn1 and parse %Cpu(s): line for us (user+sys)
    cpu_line=$(top -b -n1 | head -n 5 | grep -i "%Cpu" || true)
    if [ -n "$cpu_line" ]; then
      # extract combined usage: 100 - idle
      idle=$(echo "$cpu_line" | awk -F',' '{for(i=1;i<=NF;i++){if($i ~ /id/){print $i}}}' | sed 's/[^0-9\.]//g' || echo "0")
      cpu_use=$(awk "BEGIN{print 100 - $idle}")
    else
      # fallback: use mpstat or /proc/stat
      cpu_use=0
    fi

    mem_used=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
    # shift history left
    cpu_hist=("${cpu_hist[@]:1}" "$cpu_use")
    mem_hist=("${mem_hist[@]:1}" "$mem_used")

    # produce graph file
    {
      printf "ASCII Live CPU / RAM Graph (updates every 1s) - %s\n\n" "$(timestamp)"
      printf "CPU %%:\n"
      for val in "${cpu_hist[@]}"; do
        bars=$(printf "%0.s#" $(seq 1 $((val/2>0?val/2:0)))) # scale /2 to fit
        printf "|%-20s| %3s%%\n" "$bars" "$val"
      done
      echo; echo "MEM %:"
      for val in "${mem_hist[@]}"; do
        bars=$(printf "%0.s*" $(seq 1 $((val/2>0?val/2:0))))
        printf "|%-20s| %3s%%\n" "$bars" "$val"
      done
      echo
      echo "Press Cancel to return to menu."
    } > "$TMPGRAPH"

    sleep 1 &
    wait $!
    dialog --title "ASCII CPU/RAM Graph (press Cancel to stop)" --textbox "$TMPGRAPH" 30 80 || break
  done
}

# ---- feature: network speed monitor (real-time) ----
network_speed_monitor() {
  # choose interface
  iface=$(ls /sys/class/net | tr '\n' ' ' | awk '{print $0}' )
  iface_choice=$(dialog --stdout --inputbox "Enter interface to monitor (e.g., eth0, enp0s3, wlp2s0)\nAvailable: $(ls /sys/class/net | tr '\n' ' ')" 10 80) || return
  [ -z "$iface_choice" ] && return
  if [ ! -d "/sys/class/net/$iface_choice" ]; then
    dialog --msgbox "Interface $iface_choice not found." 6 50
    return
  fi
  # live monitor using /sys counters
  prev_rx=$(cat "/sys/class/net/$iface_choice/statistics/rx_bytes")
  prev_tx=$(cat "/sys/class/net/$iface_choice/statistics/tx_bytes")
  while true; do
    sleep 1
    rx=$(cat "/sys/class/net/$iface_choice/statistics/rx_bytes")
    tx=$(cat "/sys/class/net/$iface_choice/statistics/tx_bytes")
    drx=$((rx - prev_rx))
    dtx=$((tx - prev_tx))
    prev_rx=$rx; prev_tx=$tx
    # convert to KB/s or MB/s
    format() {
      local v=$1
      if [ $v -ge 1048576 ]; then printf "%.2f MB/s" "$(awk "BEGIN{print $v/1048576}")"
      elif [ $v -ge 1024 ]; then printf "%.2f KB/s" "$(awk "BEGIN{print $v/1024}")"
      else printf "%d B/s" "$v"; fi
    }
    drx_f=$(format $drx)
    dtx_f=$(format $dtx)
    echo "Interface: $iface_choice" > "$PROCLIST"
    echo "Updated: $(timestamp)" >> "$PROCLIST"
    echo "" >> "$PROCLIST"
    echo "RX: $drx_f" >> "$PROCLIST"
    echo "TX: $dtx_f" >> "$PROCLIST"
    echo "" >> "$PROCLIST"
    echo "Press Cancel to stop." >> "$PROCLIST"
    dialog --title "Network Speed Monitor - $iface_choice" --textbox "$PROCLIST" 10 50 || break
  done
}

# ---- feature: disk I/O monitor (iostat) ----
disk_io_monitor() {
  if ! command -v iostat >/dev/null 2>&1; then
    dialog --yesno "iostat (sysstat) not installed. Install now?" 8 60
    if [ $? -eq 0 ]; then
      sudo apt update && sudo apt install -y sysstat
    else
      dialog --msgbox "Disk I/O monitor unavailable without sysstat." 6 50
      return
    fi
  fi
  dialog --msgbox "iostat will run and show device I/O stats. Press Cancel to stop display." 8 60
  # produce a single snapshot with extended stats
  iostat -dx 1 3 > "$PROCLIST" 2>/dev/null || iostat -dx > "$PROCLIST" 2>/dev/null
  dialog --title "Disk I/O (iostat sample)" --textbox "$PROCLIST" 30 110
}

# ---- feature: service manager (list/start/stop/restart) ----
service_manager() {
  if ! command -v systemctl >/dev/null 2>&1; then
    dialog --msgbox "systemctl not found on this system." 6 50
    return
  fi
  # list services (top running)
  systemctl list-units --type=service --state=running --no-pager > "$PROCLIST" 2>/dev/null || true
  dialog --title "Running services (press OK to continue)" --textbox "$PROCLIST" 30 110
  srv=$(dialog --stdout --inputbox "Enter service name to manage (e.g., ssh, apache2):" 8 60) || return
  [ -z "$srv" ] && return
  op=$(dialog --stdout --menu "Action for $srv" 10 50 3 1 "status" 2 "start" 3 "stop") || return
  case "$op" in
    1) sudo systemctl status "$srv" --no-pager > "$PROCLIST" 2>&1; dialog --textbox "$PROCLIST" 30 100 ;;
    2) sudo systemctl start "$srv" 2>/dev/null && dialog --msgbox "Service $srv started." 6 50 || dialog --msgbox "Failed to start $srv." 6 50 ;;
    3) sudo systemctl stop "$srv" 2>/dev/null && dialog --msgbox "Service $srv stopped." 6 50 || dialog --msgbox "Failed to stop $srv." 6 50 ;;
  esac
}

# ---- feature: zombie detector ----
zombie_detector() {
  ps -eo stat,pid,ppid,cmd | awk '$1 ~ /Z/ {print}' > "$PROCLIST" || true
  if [ ! -s "$PROCLIST" ]; then
    dialog --msgbox "No zombie processes detected." 6 50
  else
    dialog --title "Zombie processes" --textbox "$PROCLIST" 12 100
  fi
}

# ---- feature: CPU temp / sensors ----
cpu_sensors() {
  if ! command -v sensors >/dev/null 2>&1; then
    dialog --yesno "lm-sensors not installed. Install now?" 8 60
    if [ $? -eq 0 ]; then
      sudo apt update && sudo apt install -y lm-sensors
      sudo sensors-detect --auto
    else
      dialog --msgbox "CPU sensors not available." 6 50
      return
    fi
  fi
  sensors > "$PROCLIST" 2>/dev/null || echo "No sensors output" > "$PROCLIST"
  dialog --title "CPU / Sensors" --textbox "$PROCLIST" 20 100
}

# ---- feature: high CPU alert ----
HIGH_CPU_THRESHOLD=80
high_cpu_alert_menu() {
  thr=$(dialog --stdout --inputbox "Current high-CPU alert threshold (percent):" 8 60 "$HIGH_CPU_THRESHOLD") || return
  if [ -n "$thr" ]; then
    if [[ "$thr" =~ ^[0-9]+$ ]]; then
      HIGH_CPU_THRESHOLD=$thr
      dialog --msgbox "Threshold set to $HIGH_CPU_THRESHOLD%." 6 50
    else
      dialog --msgbox "Invalid value." 6 40
    fi
  fi
  # run a single check
  check_high_cpu_once
}

check_high_cpu_once() {
  # check top 5 processes by cpu
  ps aux --sort=-%cpu | awk 'NR>1 && NR<=6 {printf "%s %s%% %s\n",$2,$3,$11}' > "$TMPDIR/topcpu.txt"
  # find any with cpu > threshold
  alert_lines=$(awk -v T="$HIGH_CPU_THRESHOLD" '{if($2+0 > T) print}' "$TMPDIR/topcpu.txt" || true)
  if [ -n "$alert_lines" ]; then
    dialog --title "High CPU Alert" --msgbox "Processes exceeding ${HIGH_CPU_THRESHOLD}% CPU:\n\n$(cat $TMPDIR/topcpu.txt)" 12 70
    ensure_logfile
    echo "$(timestamp) | HIGH_CPU_ALERT | threshold:$HIGH_CPU_THRESHOLD | top:" >> "$LOGFILE"
    cat "$TMPDIR/topcpu.txt" >> "$LOGFILE"
  else
    dialog --msgbox "No processes exceed ${HIGH_CPU_THRESHOLD}% CPU right now." 8 60
  fi
}

# ---- feature: export system report (HTML & Markdown) ----
export_report() {
  mkdir -p "$REPORTDIR"
  fname="system_report_$(date +%Y%m%d_%H%M%S)"
  html="$REPORTDIR/$fname.html"
  md="$REPORTDIR/$fname.md"

  {
    echo "<html><head><meta charset='utf-8'><title>System Report - $fname</title></head><body>"
    echo "<h1>System Report - $(timestamp)</h1>"
    echo "<h2>Uptime</h2><pre>$(uptime)</pre>"
    echo "<h2>Free / Mem</h2><pre>$(free -h)</pre>"
    echo "<h2>Top (one-shot)</h2><pre>$(top -b -n1 | head -n 20)</pre>"
    echo "<h2>Disk Usage</h2><pre>$(df -h)</pre>"
    echo "<h2>Top Processes (by CPU)</h2><pre>$(ps aux --sort=-%cpu | head -n 20)</pre>"
    echo "<h2>Running Services</h2><pre>$(systemctl list-units --type=service --state=running --no-pager | head -n 40)</pre>"
    if command -v sensors >/dev/null 2>&1; then
      echo "<h2>Sensors</h2><pre>$(sensors || echo 'sensors failed')</pre>"
    fi
    echo "</body></html>"
  } > "$html"

  {
    echo "# System Report - $fname"
    echo "Generated: $(timestamp)"
    echo
    echo "## Uptime"
    uptime
    echo
    echo "## Free / Mem"
    free -h
    echo
    echo "## Top (one-shot)"
    top -b -n1 | head -n 20
    echo
    echo "## Disk Usage"
    df -h
    echo
    echo "## Top Processes (by CPU)"
    ps aux --sort=-%cpu | head -n 20
    echo
    echo "## Running Services"
    systemctl list-units --type=service --state=running --no-pager | head -n 40
    if command -v sensors >/dev/null 2>&1; then
      echo
      echo "## Sensors"
      sensors || true
    fi
  } > "$md"

  dialog --msgbox "Reports created:\n$html\n$md" 10 70
}

# ---- feature: view log ----
show_log() {
  ensure_logfile
  dialog --title "Process Manager Pro Log ($LOGFILE)" --textbox "$LOGFILE" 30 110
}

# ---- help ----
show_help() {
  dialog --title "About - Process Manager Pro" --msgbox "Process Manager Pro\n\nFeatures:\n- View/search/kill processes\n- Fuzzy selection with fzf (if installed)\n- Priority management (nice/renice)\n- Live monitor and ASCII CPU/RAM graph\n- Network speed monitor (per-interface)\n- Disk I/O (iostat)\n- Service management (systemctl)\n- Zombie detector\n- CPU temperature via lm-sensors\n- High-CPU alerts and logging\n- Export HTML/Markdown system report\n\nDependencies (recommended): dialog lm-sensors sysstat fzf\nLogs saved to: $LOGFILE\nReports saved to: $REPORTDIR\n" 18 80
}

# ---- start checks ----
if ! command -v dialog >/dev/null 2>&1; then
  echo "This script needs 'dialog'. Install with: sudo apt install dialog"
  exit 1
fi

ensure_logfile
main_menu
