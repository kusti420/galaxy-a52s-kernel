#!/bin/sh
# Copies our commits on top of sc7280-mainline's sc7280-7.3.y in the (untracked) linux-7.3/
# worktree (branch a52sxq-7.3 of linux/) into patches/mainline-7.3/ as a numbered series, so
# they are versioned with the rest of the project. Run before every commit that touched
# linux-7.3/. The config fragment lives only in patches/mainline-7.3/a52sxq-ml.config.
# Recreate the tree: git -C linux fetch --depth 1 origin sc7280-7.3.y
#   git -C linux worktree add -b a52sxq-7.3 ../linux-7.3 origin/sc7280-7.3.y
#   git -C linux-7.3 am ../patches/mainline-7.3/*.patch
set -e
cd "$(dirname "$0")"
rm -f patches/mainline-7.3/*.patch
git -C linux-7.3 format-patch -q --no-signature -o ../patches/mainline-7.3 origin/sc7280-7.3.y
ls patches/mainline-7.3
