echo "Preserve docked lid handling during logout and at the login screen"

if ! systemctl is-enabled --quiet omarchy-docked-lid-inhibit.service; then
  sudo systemctl daemon-reload
  sudo systemctl enable --now omarchy-docked-lid-inhibit.service
fi
