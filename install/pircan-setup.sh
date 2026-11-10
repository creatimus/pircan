#!/bin/bash
# PIRCAN setup: runs the guided installer from https://pircan.creatimus.com (read it: https://pircan.creatimus.com/install.sh)
cd "$HOME" || exit 1
clear
curl -fsSL "https://pircan.creatimus.com/install.sh" | bash
echo
read -r -p "Press Return to close this window. " _
