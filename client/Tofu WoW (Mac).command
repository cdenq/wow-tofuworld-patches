#!/bin/bash
# Mac players: update Tofu Worldview and start WoW. Windows players use "Tofu WoW (Windows).bat" instead.
# First time only: open Terminal, type "bash " (with a space), drag this file into the window, and press Return. After that you can double-click it.
cd "$(dirname "$0")" || exit 1
if [ ! -f "Tofu/tofu-patcher.sh" ]; then
  echo "The Tofu folder is missing. Unzip the whole client again, or ask Chris."
else
  bash "Tofu/tofu-patcher.sh" --launch
fi
echo
read -r -p "Press Return to close this window. " _
