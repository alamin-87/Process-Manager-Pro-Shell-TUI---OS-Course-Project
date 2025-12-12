# Process Manager Pro (Shell TUI) - OS Course Project

## Summary
Process Manager Pro is a Bash-based terminal UI using `dialog` that provides advanced system/process management utilities for Ubuntu. Designed for VirtualBox Ubuntu and OS coursework demos.

## Features
- View, sort and search processes
- Kill processes (menu + fuzzy `fzf` selection fallback)
- Change process priority (nice/renice)
- One-shot `top` snapshot
- Live auto-refresh monitor
- ASCII CPU/RAM graphs (live)
- Network speed monitor (per-interface)
- Disk I/O monitor using `iostat`
- Service manager (systemctl)
- Zombie process detector
- CPU temperature / sensors
- High-CPU alert with configurable threshold
- Export system report (HTML / Markdown)
- Action logging: `~/.process_manager_pro.log`

## Requirements
- Ubuntu (VirtualBox)
- bash
- dialog (required)
- Optional but recommended:
  - lm-sensors (`sensors`) for CPU temps
  - sysstat (`iostat`) for disk I/O stats
  - fzf for fuzzy process selection

Install recommended tools:
```bash
sudo apt update
sudo apt install -y dialog lm-sensors sysstat fzf
sudo sensors-detect --auto   # run once to initialize sensors

## Author & Links

- Personal Portfolio: https://personalportfolioalamin.netlify.app/
- LinkedIn: https://www.linkedin.com/in/alamin87/
- GitHub: https://github.com/alamin-87
