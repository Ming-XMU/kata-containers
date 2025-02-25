#!/usr/bin/env bash
#
# Copyright (c) 2018-2020 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -e

KATA_REPO=${KATA_REPO:-github.com/kata-containers/kata-containers}
MUSL_VERSION=${MUSL_VERSION:-"null"}
# Give preference to variable set by CI
yq_file="${script_dir}/../../../ci/install_yq.sh"
kata_versions_file="${script_dir}/../../../versions.yaml"

error()
{
	local msg="$*"
	echo "ERROR: ${msg}" >&2
}

die()
{
	error "$*"
	exit 1
}

OK()
{
	local msg="$*"
	echo "[OK] ${msg}" >&2
}

info()
{
	local msg="$*"
	echo "INFO: ${msg}"
}

warning()
{
	local msg="$*"
	echo "WARNING: ${msg}"
}

check_program()
{
	type "$1" >/dev/null 2>&1
}

check_root()
{
	if [ "$(id -u)" != "0" ]; then
		echo "Root is needed"
		exit 1
	fi
}

generate_dnf_config()
{
	cat > "${DNF_CONF}" << EOF
[main]
reposdir=/root/mash

[base]
name=${OS_NAME}-${OS_VERSION} base
releasever=${OS_VERSION}
EOF
	if [ "$BASE_URL" != "" ]; then
		echo "baseurl=$BASE_URL" >> "$DNF_CONF"
	elif [ "$METALINK" != "" ]; then
		echo "metalink=$METALINK" >> "$DNF_CONF"
	fi

	if [ -n "$GPG_KEY_URL" ]; then
		if [ ! -f "${CONFIG_DIR}/${GPG_KEY_FILE}" ]; then
			curl -L "${GPG_KEY_URL}" -o "${CONFIG_DIR}/${GPG_KEY_FILE}"
		fi
		cat >> "${DNF_CONF}" << EOF
gpgcheck=1
gpgkey=file://${CONFIG_DIR}/${GPG_KEY_FILE}
EOF
	fi

}

build_rootfs()
{
	# Mandatory
	local ROOTFS_DIR="$1"

	[ -z "$ROOTFS_DIR" ] && die "need rootfs"

	# In case of support EXTRA packages, use it to allow
	# users add more packages to the base rootfs
	local EXTRA_PKGS=${EXTRA_PKGS:-""}

	#PATH where files this script is placed
	#Use it to refer to files in the same directory
	#Exmaple: ${CONFIG_DIR}/foo
	#local CONFIG_DIR=${CONFIG_DIR}

	check_root
	if [ ! -f "${DNF_CONF}" ] && [ -z "${DISTRO_REPO}" ] ; then
		DNF_CONF="./kata-${OS_NAME}-dnf.conf"
		generate_dnf_config
	fi
	mkdir -p "${ROOTFS_DIR}"
	if [ -n "${PKG_MANAGER}" ]; then
		info "DNF path provided by user: ${PKG_MANAGER}"
	elif check_program "dnf"; then
		PKG_MANAGER="dnf"
	elif check_program "yum" ; then
		PKG_MANAGER="yum"
	else
		die "neither yum nor dnf is installed"
	fi

	DNF="${PKG_MANAGER} -y --installroot=${ROOTFS_DIR} --noplugins"
	if [ -n "${DNF_CONF}" ] ; then
		DNF="${DNF} --config=${DNF_CONF}"
	else
		DNF="${DNF} --releasever=${OS_VERSION}"
	fi

	info "install packages for rootfs"
	$DNF install ${EXTRA_PKGS} ${PACKAGES}

	rm -rf ${ROOTFS_DIR}/usr/share/{bash-completion,cracklib,doc,info,locale,man,misc,pixmaps,terminfo,zoneinfo,zsh}
}

# Create a YAML metadata file inside the rootfs.
#
# This provides useful information about the rootfs than can be interrogated
# once the rootfs has been converted into a image/initrd.
create_summary_file()
{
	local -r rootfs_dir="$1"

	[ -z "$rootfs_dir" ] && die "need rootfs"

	local -r file_dir="/var/lib/osbuilder"
	local -r dir="${rootfs_dir}${file_dir}"

	local -r filename="osbuilder.yaml"
	local file="${dir}/${filename}"

	local -r now=$(date -u -d@${SOURCE_DATE_EPOCH:-$(date +%s.%N)} '+%Y-%m-%dT%T.%N%zZ')

	# sanitise package lists
	PACKAGES=$(echo "$PACKAGES"|tr ' ' '\n'|sort -u|tr '\n' ' ')
	EXTRA_PKGS=$(echo "$EXTRA_PKGS"|tr ' ' '\n'|sort -u|tr '\n' ' ')

	local -r packages=$(for pkg in ${PACKAGES}; do echo "      - \"${pkg}\""; done)
	local -r extra=$(for pkg in ${EXTRA_PKGS}; do echo "      - \"${pkg}\""; done)

	mkdir -p "$dir"

	# Semantic version of the summary file format.
	#
	# XXX: Increment every time the format of the summary file changes!
	local -r format_version="0.0.2"

	local -r osbuilder_url="https://github.com/kata-containers/kata-containers/tools/osbuilder"

	local agent="${AGENT_DEST}"
	[ "$AGENT_INIT" = yes ] && agent="${init}"

	local -r agentdir="${script_dir}/../../../"
	local -r agent_version=$(cat ${agentdir}/VERSION)

	cat >"$file"<<-EOF
	---
	osbuilder:
	  url: "${osbuilder_url}"
	  version: "${OSBUILDER_VERSION}"
	rootfs-creation-time: "${now}"
	description: "osbuilder rootfs"
	file-format-version: "${format_version}"
	architecture: "${ARCH}"
	base-distro:
	  name: "${OS_NAME}"
	  version: "${OS_VERSION}"
	  packages:
	    default:
${packages}
	    extra:
${extra}
	agent:
	  url: "https://${KATA_REPO}"
	  name: "${AGENT_BIN}"
	  version: "${agent_version}"
	  agent-is-init-daemon: "${AGENT_INIT}"
EOF

	local rootfs_file="${file_dir}/$(basename "${file}")"
	info "Created summary file '${rootfs_file}' inside rootfs"
}

# generate_dockerfile takes as only argument a path. It expects a Dockerfile.in
# Dockerfile template to be present in that path, and will generate a usable
# Dockerfile replacing the '@PLACEHOLDER@' in that Dockerfile
generate_dockerfile()
{
	dir="$1"
	[ -d "${dir}" ] || die "${dir}: not a directory"

	local architecture=$(uname -m)
	local rustarch=${architecture}
	local muslarch=${architecture}
	local libc=musl
	case "$(uname -m)" in
		"ppc64le")
			rustarch=powerpc64le
			muslarch=powerpc64
			libc=gnu
			;;
		"s390x")
			libc=gnu
			;;

		*)
			;;
	esac

	[ -n "${http_proxy:-}" ] && readonly set_proxy="RUN sed -i '$ a proxy="${http_proxy:-}"' /etc/dnf/dnf.conf /etc/yum.conf; true"

	# Rust agent
	# rust installer should set path apropiately, just in case
	# install musl for compiling rust-agent
	local musl_source_url="https://git.zv.io/toolchains/musl-cross-make.git"
	local musl_source_dir="musl-cross-make"
	install_musl=
	if [ "${muslarch}" == "aarch64" ]; then
		local musl_tar="${muslarch}-linux-musl-native.tgz"
		local musl_dir="${muslarch}-linux-musl-native"
		local aarch64_musl_target="aarch64-linux-musl"
		install_musl="
RUN cd /tmp; \
	mkdir -p /usr/local/musl/; \
	if curl -sLO --fail https://musl.cc/${musl_tar}; then \
		tar -zxf ${musl_tar}; \
		cp -r ${musl_dir}/* /usr/local/musl/; \
	else \
		git clone ${musl_source_url}; \
		TARGET=${aarch64_musl_target} make -j$(nproc) -C ${musl_source_dir} install; \
		cp -r ${musl_source_dir}/output/* /usr/local/musl/; \
		cp /usr/local/musl/bin/aarch64-linux-musl-g++ /usr/local/musl/bin/g++; \
	fi
ENV PATH=\$PATH:/usr/local/musl/bin
RUN ln -sf /usr/local/musl/bin/g++ /usr/bin/g++
"
	else
		local musl_tar="musl-${MUSL_VERSION}.tar.gz"
		local musl_dir="musl-${MUSL_VERSION}"
		install_musl="
RUN pushd /root; \
    curl -sLO https://www.musl-libc.org/releases/${musl_tar}; tar -zxf ${musl_tar}; \
	cd ${musl_dir}; \
	sed -i \"s/^ARCH = .*/ARCH = ${muslarch}/g\" dist/config.mak; \
	./configure > /dev/null 2>\&1; \
	make > /dev/null 2>\&1; \
	make install > /dev/null 2>\&1; \
	echo \"/usr/local/musl/lib\" > /etc/ld-musl-${muslarch}.path; \
	popd
ENV PATH=\$PATH:/usr/local/musl/bin
"
	fi

	readonly install_rust="
RUN curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSLf --output /tmp/rust-init; \
    chmod a+x /tmp/rust-init; \
	export http_proxy=${http_proxy:-}; \
	export https_proxy=${http_proxy:-}; \
	/tmp/rust-init -y --default-toolchain ${RUST_VERSION}
RUN . /root/.cargo/env; \
    export http_proxy=${http_proxy:-}; \
	export https_proxy=${http_proxy:-}; \
	cargo install cargo-when; \
	rustup target install ${rustarch}-unknown-linux-${libc}
RUN ln -sf /usr/bin/g++ /bin/musl-g++
"
	pushd "${dir}"
	dockerfile_template="Dockerfile.in"
	dockerfile_arch_template="Dockerfile-${architecture}.in"
	# if arch-specific docker file exists, swap the univesal one with it.
        if [ -f "${dockerfile_arch_template}" ]; then
                dockerfile_template="${dockerfile_arch_template}"
        else
                [ -f "${dockerfile_template}" ] || die "${dockerfile_template}: file not found"
        fi

	# ppc64le and s390x have no musl target
	if [ "${architecture}" == "ppc64le" ] || [ "${architecture}" == "s390x" ]; then
		sed \
			-e "s|@OS_VERSION@|${OS_VERSION:-}|g" \
			-e "s|@INSTALL_MUSL@||g" \
			-e "s|@INSTALL_RUST@|${install_rust//$'\n'/\\n}|g" \
			-e "s|@SET_PROXY@|${set_proxy:-}|g" \
			"${dockerfile_template}" > Dockerfile
	else
		sed \
			-e "s|@OS_VERSION@|${OS_VERSION:-}|g" \
			-e "s|@INSTALL_MUSL@|${install_musl//$'\n'/\\n}|g" \
			-e "s|@INSTALL_RUST@|${install_rust//$'\n'/\\n}|g" \
			-e "s|@SET_PROXY@|${set_proxy:-}|g" \
			"${dockerfile_template}" > Dockerfile
	fi
	popd
}

get_package_version_from_kata_yaml()
{
    local yq_path="$1"
    local yq_version
    local yq_args

	typeset -r yq=$(command -v yq || command -v "${GOPATH}/bin/yq" || echo "${GOPATH}/bin/yq")
	if [ ! -f "$yq" ]; then
		source "$yq_file"
	fi

    yq_version=$($yq -V)
    case $yq_version in
    *"version "[1-3]*)
        yq_args="r -X - ${yq_path}"
        ;;
    *)
        yq_args="e .${yq_path} -"
        ;;
    esac

	PKG_VERSION="$(cat "${kata_versions_file}" | $yq ${yq_args})"

	[ "$?" == "0" ] && [ "$PKG_VERSION" != "null" ] && echo "$PKG_VERSION" || echo ""
}

detect_rust_version()
{
	info "Detecting agent rust version"
    local yq_path="languages.rust.meta.newest-version"

	info "Get rust version from ${kata_versions_file}"
	RUST_VERSION="$(get_package_version_from_kata_yaml "$yq_path")"

	[ -n "$RUST_VERSION" ]
}

detect_musl_version()
{
	info "Detecting musl version"
    local yq_path="externals.musl.version"

	info "Get musl version from ${kata_versions_file}"
	MUSL_VERSION="$(get_package_version_from_kata_yaml "$yq_path")"

	[ -n "$MUSL_VERSION" ]
}

before_starting_container() {
	return 0
}

after_stopping_container() {
	return 0
}
