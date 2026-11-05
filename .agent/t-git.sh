#!/bin/bash
echo "PATH-has-local=$(case ":$PATH:" in *":$HOME/.local/bin:"*) echo yes;; *) echo no;; esac)"
git ls-remote git@github.com:SQL0106/sshkit.git | head -1
echo "rc-ok"
