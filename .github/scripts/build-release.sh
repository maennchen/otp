#!/usr/bin/env bash

## %CopyrightBegin%
##
## SPDX-License-Identifier: Apache-2.0
##
## Copyright Ericsson AB 2025. All Rights Reserved.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
## %CopyrightEnd%

set -Eeuxo pipefail

################################################################################
# Helpers
################################################################################

function usage() {
    cat <<EOF
Usage ${SCRIPT_NAME} [options] -- [version] [target]

Options:
    -h          Show this help and exit
    -c          This is a cross-compile build, use the host architecture
                for the build and target architecture for the release.
                This is useful when building on a different architecture
                than the target (e.g., x86_64 to aarch64).
                Tests will be skipped in this mode.

Arguments:
    version     The OTP version to build, e.g., "OTP-28.0.2"
    target      The target architecture, e.g., "x86_64-unknown-linux-musl"
                or "aarch64-apple-darwin".
EOF
}

function log() {
    printf '%s\n' "$*" >&2;
}

function die() {
    log "error: $*";
    exit 1;
}

################################################################################
# Read Options
################################################################################

TARGET=""
ARCH=""
VENDOR=""
SYSTEM=""
ABI=""
VERSION=""
CROSS=false

function read_opts() {
    local POS_ARGS=()
    local PARSED

    if ! PARSED=$(getopt "hc" "$@"); then
        # getopt already printed an error
        exit 2
    fi

    # shellcheck disable=SC2086  # we want word-splitting from eval set --
    eval set -- $PARSED

    while true; do
        case "$1" in
            -h)     usage; exit 0 ;;
            -c)     CROSS=true; shift ;;
            --)     shift; break ;;
            *)      die "internal parsing error: $1" ;;
        esac
    done

    if (( $# > 0 )); then
        # collect to array safely
        while (( $# > 0 )); do POS_ARGS+=("$1"); shift; done
    fi

    VERSION="${POS_ARGS[0]:-}"
    TARGET="${POS_ARGS[1]:-}"
}

function check_opts() {
    [[ -n "$TARGET" ]] || die "target argument is required"
    [[ -n "$VERSION" ]] || die "version argument is required"
}

function parse_target() {
    local -a PARTS=()

    # Split on dashes into an array (works on bash 3+)
    IFS='-' read -r -a PARTS <<< "$TARGET"

    # Assign required pieces; allow 2–3–4(+)-part variants
    # shellcheck disable=SC2034
    case "${#PARTS[@]}" in
        0) ;;  # nothing
        1) ARCH="${PARTS[0]}" ;;
        2) ARCH="${PARTS[0]}";                       SYSTEM="${PARTS[1]}" ;;
        3) ARCH="${PARTS[0]}"; VENDOR="${PARTS[1]}"; SYSTEM="${PARTS[2]}" ;;
        *) ARCH="${PARTS[0]}"; VENDOR="${PARTS[1]}"; SYSTEM="${PARTS[2]}";
            # Join the rest back with '-' as ABI/environment
            ABI="${PARTS[3]}"
            for ((i=4; i<${#PARTS[@]}; i++)); do
                ABI+="-${PARTS[$i]}"
            done
            ;;
    esac
}

function init_options() {
    read_opts "$@"
    check_opts
    parse_target
}

################################################################################
# Compile and Build
################################################################################

function setup_env() {
    export ERL_TOP="$PWD"
    export MAKEFLAGS=-j$(($(nproc) + 2))
    export ERLC_USE_SERVER=true
    export ERTS_SKIP_DEPEND=true
    export RELEASE_LIBBEAM=yes

    case "$SYSTEM" in
        darwin)
            export CFLAGS="-Os -fno-common -mmacosx-version-min=11.0"
            ;;
        *)  ;;
    esac

    ulimit -n 65536
}

function configure() {
    local CONFIGURE_ARGS=(
        "--prefix=$ERL_TOP/release"
    )

    # Set Host / Build / Target Info
    case "$SYSTEM" in
        windows)
            local ARCH_PARAM

            case "$ARCH" in
                aarch64)    ARCH_PARAM="x64_arm64" ;;
                i686)       ARCH_PARAM="x86" ;;
                x86_64)     ARCH_PARAM="x64" ;;
                *)          die "Unsupported Windows architecture: $ARCH" ;;
            esac

            eval "$(./otp_build env_win32 "$ARCH_PARAM")"
            ;;
        *)
            CONFIGURE_ARGS+=("--host=$TARGET" "--target=$TARGET")
            ;;
    esac

    # JIT Flags
    if [[ "$SYSTEM" == "darwin" ]] && echo "$VERSION" | grep -q "^OTP-25"; then
        CONFIGURE_ARGS+=("--disable-jit")
    fi

    ./otp_build configure "${CONFIGURE_ARGS[@]}"
}

function build_os_specific_tools() {
    case "$SYSTEM" in
        windows)
            ./otp_build debuginfo_win32
            ./otp_build installer_win32
            ;;
        *)  ;;
    esac
}

function compile() {
    setup_env
    configure
    ./otp_build boot -a
    ./otp_build release -a
    build_os_specific_tools
}

################################################################################
# Test
################################################################################

function test() {
    if [[ "$CROSS" == true ]]; then
        log "Cross-compile mode enabled, skipping tests."
        return
    fi

    ./otp_build tests

    # "$ERL_TOP/release/Install" -sasl "$ERL_TOP/smoke-test-install"

    echo "=================== List files in release directory:"
    find "$ERL_TOP/release" -print

    echo "=================== List files in smoke test directory:"
    find "$ERL_TOP/smoke-test-install" -print

    PATH="$ERL_TOP/smoke-test-install/bin:$PATH" erl \
        -noshell -eval <<'ERL'
io:format("~s~s~n", [
erlang:system_info(system_version),
erlang:system_info(system_architecture)]),
{ok, _} = application:ensure_all_started(crypto), io:format("crypto ok~n"),
halt().
ERL
}

################################################################################
# Main Execution
################################################################################

main() {
    init_options "$@"
    compile
    # TODO: Figure out testing
    # test
}

main "$@"
