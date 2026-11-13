#!/bin/sh
# Render the diagrams with the video project's puppeteer and Chrome headless shell.
cd "$(dirname "$0")"
V=../../video/node_modules
CHROME=$(ls -d $V/.remotion/chrome-headless-shell/*/chrome-headless-shell-*/chrome-headless-shell | head -1) \
PUPPETEER_FROM=$(cd $V && pwd) node render.mjs "$@"
