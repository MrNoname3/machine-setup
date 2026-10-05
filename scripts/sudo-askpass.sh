#!/bin/sh
# Ask the sudo password in a desktop dialog, for runs without a terminal:
#
#   ./scripts/apply.sh desktop-bazzite --become-password-file scripts/sudo-askpass.sh
#
# Ansible runs an executable password file and reads the password from its
# output, so the password never touches the disk.
exec "${SUDO_ASKPASS:-/usr/bin/ksshaskpass}" "Sudo password for the machine-setup playbook"
