#!/bin/bash
set -u
x="a b 'c'"
echo "file-mode-quote: [$x]"
printf 'pipe %s\n' "$x" | tr 'a-z' 'A-Z'
echo "home=$HOME"
