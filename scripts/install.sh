#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repository_root/nicp_cdk"
nimble --sync -y install
nimble path nicp_cdk
nicp cHeaders
