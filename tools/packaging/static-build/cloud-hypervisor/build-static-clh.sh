#!/usr/bin/env bash
#
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

ARCH=$(uname -m)

# Currently, Cloud Hypervisor only support arm64 and x86_64
[ "${ARCH}" != "aarch64" ] && [ "${ARCH}" != "x86_64" ] && exit

script_dir=$(dirname $(readlink -f "$0"))
kata_version="${kata_version:-}"
force_build_from_source="${force_build_from_source:-false}"
features="${features:-}"

source "${script_dir}/../../scripts/lib.sh"

cloud_hypervisor_repo="${cloud_hypervisor_repo:-}"
cloud_hypervisor_version="${cloud_hypervisor_version:-}"

if [ -z "$cloud_hypervisor_repo" ]; then
       info "Get cloud_hypervisor information from runtime versions.yaml"
       cloud_hypervisor_url=$(get_from_kata_deps "assets.hypervisor.cloud_hypervisor.url" "${kata_version}")
       [ -n "$cloud_hypervisor_url" ] || die "failed to get cloud_hypervisor url"
       cloud_hypervisor_repo="${cloud_hypervisor_url}.git"
fi
[ -n "$cloud_hypervisor_repo" ] || die "failed to get cloud_hypervisor repo"

[ -n "$cloud_hypervisor_version" ] || cloud_hypervisor_version=$(get_from_kata_deps "assets.hypervisor.cloud_hypervisor.version" "${kata_version}")
[ -n "$cloud_hypervisor_version" ] || die "failed to get cloud_hypervisor version"

pull_clh_released_binary() {
    info "Download cloud-hypervisor version: ${cloud_hypervisor_version}"
    cloud_hypervisor_binary="https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/${cloud_hypervisor_version}/cloud-hypervisor-static"

    curl --fail -L ${cloud_hypervisor_binary} -o cloud-hypervisor-static || return 1
    mkdir -p cloud-hypervisor
    mv -f cloud-hypervisor-static cloud-hypervisor/cloud-hypervisor
    chmod +x cloud_hypervisor/cloud-hypervisor
}

build_clh_from_source() {
    info "Build ${cloud_hypervisor_repo} version: ${cloud_hypervisor_version}"
    repo_dir=$(basename "${cloud_hypervisor_repo}")
    repo_dir="${repo_dir//.git}"
    [ -d "${repo_dir}" ] || git clone "${cloud_hypervisor_repo}"
    pushd "${repo_dir}"
    git fetch || true
    git checkout "${cloud_hypervisor_version}"
    if [ -n "${features}" ]; then
        info "Build cloud-hypervisor enabling the following features: ${features}"
        ./scripts/dev_cli.sh build --release --libc musl --features "${features}"
    else
        ./scripts/dev_cli.sh build --release --libc musl
    fi
    rm -f cloud-hypervisor
    cp build/cargo_target/$(uname -m)-unknown-linux-musl/release/cloud-hypervisor .
    popd
}

if [ "${ARCH}" == "aarch64" ]; then
    info "aarch64 binaries are not distributed as part of the Cloud Hypervisor releases, forcing to build from source"
    force_build_from_source="true"
fi

if [ -n "${features}" ]; then
    info "As an extra build argument has been passed to the script, forcing to build from source"
    force_build_from_source="true"
fi

if [ "${force_build_from_source}" == "true" ]; then
    info "Build cloud-hypervisor from source as it's been request via the force_build_from_source flag"
    build_clh_from_source
else
    pull_clh_released_binary || 
        (info "Failed to pull cloud-hypervisor released binary, trying to build from source" && build_clh_from_source)
fi
