#!/bin/bash
# PIRCAN setup: runs the guided installer from https://raw.githubusercontent.com/creatimus/pircan/main/install.sh (read it there first if you like)
cd "$HOME" || exit 1
clear
curl -fsSL "https://raw.githubusercontent.com/creatimus/pircan/main/install.sh" | bash
echo
read -r -p "Press Return to close this window. " _
