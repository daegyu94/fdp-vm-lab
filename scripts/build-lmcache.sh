#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

ssh_ready || die "SSH가 준비되지 않았습니다."
ssh_base sudo /usr/local/sbin/build-lmcache

