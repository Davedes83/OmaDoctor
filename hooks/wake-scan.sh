#!/bin/sh
# OmaDoctor wake hook: trigger a fresh scan when the system or session resumes.
#
# Install:
#   omarchy hook install wake ~/.config/omarchy/plugins/davedes.omadoctor/hooks/wake-scan.sh
#
# Wire to system resume:
#   /usr/lib/systemd/system-sleep/omadoctor-wake:
#     #!/bin/sh
#     [ "$1" = "post" ] || exit 0
#     su -s /bin/sh davedes -c 'omarchy hook wake'
#
# Wire to session unlock (Hyprland):
#   Add to ~/.config/hypr/hyprland.conf:
#     bind = $mainMod, M, exec, omarchy hook wake
#
# The hook calls the plugin's IPC runFullScan() method, which runs a full
# (network-inclusive) diagnosis and posts a notification only on a genuine
# worsening -- never a noisy repeat of an already-known state.
omarchy shell davedes.omadoctor runFullScan 2>/dev/null || true
