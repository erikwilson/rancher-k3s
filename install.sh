#!/bin/sh
set -e

# Usage:
#   curl ... | ENV_VAR=... sh -
#       or
#   ENV_VAR=... ./install.sh
#
# Example:
#   Installing a server without an agent:
#     curl ... | INSTALL_K3S_FLAGS="--disable-agent" sh -
#   Installing an agent to point at a server (setting K3S_URL assumes agent):
#     curl ... | K3S_TOKEN=xxx K3S_URL=https://server-url:6443 sh -  
#
# Environment variables:
#   - K3S_*
#     Environment variables which begin with K3S_ will be preserved for the
#     systemd service to use.
#
#   - INSTALL_K3S_SKIP_DOWNLOAD
#     If set to true will not download k3s hash or binary.
#
#   - INSTALL_K3S_VERSION
#     Version of k3s to download from github. Will attempt to download the
#     latest version if not specified.
#
#   - INSTALL_K3S_EXEC
#     Command with flags to use for launching k3s in the systemd service, if
#     not specified will default to "server" or "agent" if K3S_URL is set.
#     Can also be passed as an argument to the script, like:
#       curl ... | sh -s - server --disable-agent
#
#   - INSTALL_K3S_FLAGS
#     Extra flags to append to INSTALL_K3S_EXEC command
#
#   - INSTALL_K3S_NAME
#     Name of systemd service to create, will default from the k3s exec command
#     if not specified. If specified the name will be prefixed with 'k3s-'.
#
#   - INSTALL_K3S_TYPE
#     Type of systemd service to create, will default from the k3s exec command
#     if not specified.

GITHUB_URL=https://github.com/rancher/k3s/releases

# --- helper functions for logs ---
info()
{
    echo "[INFO] " "$@"
}
fatal()
{
    echo "[ERROR] " "$@"
    exit 1
}

# --- fatal if no systemd ---
verify_systemd() {
    if [ ! -d /run/systemd ]; then
        fatal "Can not find systemd to use as a process supervisor for k3s"
    fi
}

# --- define needed environment variables ---
setup_env() {
    # --- use k3s args if passed or create default ---
    if [ -z "${INSTALL_K3S_EXEC}" ]; then
        if [ -z "$1" ]; then
            if [ -z "${K3S_URL}" ]; then
                INSTALL_K3S_EXEC=server
            else
                if [ -z "${K3S_TOKEN}" ] && [ -z "${K3S_CLUSTER_SECRET}" ]; then
                    fatal "Defaulted k3s exec command to 'agent' because K3S_URL is defined, but K3S_TOKEN or K3S_CLUSTER_SECRET is not defined."
                fi
                INSTALL_K3S_EXEC=agent
            fi
        else
            INSTALL_K3S_EXEC="$@"
        fi
    fi
    INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} ${INSTALL_K3S_FLAGS}"

    # --- get the k3s command that is being called ---
    CMD_K3S=`cmd(){ echo $1; } && eval cmd ${INSTALL_K3S_EXEC}`

    # --- use systemd name if defined or create default ---
    if [ -n "${INSTALL_K3S_NAME}" ]; then
        SYSTEMD_NAME=k3s-${INSTALL_K3S_NAME}
    else
        if [ "${CMD_K3S}" = "server" ]; then
            SYSTEMD_NAME=k3s
        else
            SYSTEMD_NAME=k3s-${CMD_K3S}
        fi
    fi
    SERVICE_K3S=${SYSTEMD_NAME}.service
    UNINSTALL_K3S_SH=${SYSTEMD_NAME}-uninstall.sh

    # --- use systemd type if defined or create default ---
    if [ -z "${INSTALL_K3S_TYPE}" ]; then
        if [ "${CMD_K3S}" = "server" ]; then
            INSTALL_K3S_TYPE=notify
        else
            INSTALL_K3S_TYPE=exec
        fi
    fi

    # --- use sudo if we are not already root ---
    SUDO=sudo
    if [ `id -u` = 0 ]; then
        SUDO=
    fi
}

# --- check if skip download environment variable set ---
can_skip_download() {
    if [ "${INSTALL_K3S_SKIP_DOWNLOAD}" != "true" ]; then
        return 1
    fi
}

# --- verify an executabe k3s binary is installed ---
verify_k3s_is_executable() {
    if [ ! -x /usr/local/bin/k3s ]; then
        fatal "Executable k3s binary not found at /usr/local/bin/k3s"
    fi
}

# --- set arch and suffix, fatal if architecture not supported ---
setup_verify_arch() {
    ARCH=`uname -m`
    case $ARCH in
        amd64)
            ARCH=amd64
            SUFFIX=
            ;;
        x86_64)
            ARCH=amd64
            SUFFIX=
            ;;
        arm64)
            ARCH=arm64
            SUFFIX=-${ARCH}
            ;;
        aarch64)
            ARCH=arm64
            SUFFIX=-${ARCH}
            ;;
        arm*)
            ARCH=arm
            SUFFIX=-${ARCH}hf
            ;;
        *)
            fatal "Unsupported architecture $ARCH"
    esac
}

# --- fatal if no curl ---
verify_curl() {
    if [ -z `which curl || true` ]; then
        fatal "Can not find curl for downloading files"
    fi
}

# --- create tempory directory and cleanup when done ---
setup_tmp() {
    TMP_DIR=`mktemp -d -t k3s-install.XXXXXXXXXX`
    TMP_HASH=${TMP_DIR}/k3s.hash
    TMP_BIN=${TMP_DIR}/k3s.bin
    cleanup() {
        code=$?
        set +e
        trap - EXIT
        rm -rf ${TMP_DIR}
        exit $code
    }
    trap cleanup INT EXIT
}

# --- use desired k3s version if defined or find latest ---
get_release_version() {
    if [ -z "${INSTALL_K3S_VERSION}" ]; then
        info "Finding latest release"
        INSTALL_K3S_VERSION=`curl -w "%{url_effective}" -I -L -s -S ${GITHUB_URL}/latest -o /dev/null | sed -e 's|.*/||'`
    fi
    info "Using ${INSTALL_K3S_VERSION} as release"
}

# --- download hash from github url ---
download_hash() {
    HASH_URL=${GITHUB_URL}/download/${INSTALL_K3S_VERSION}/sha256sum-${ARCH}.txt
    info "Downloading hash ${HASH_URL}"
    curl -o ${TMP_HASH} -sfL ${HASH_URL} || fatal "Hash download failed"
    HASH_EXPECTED=`grep k3s ${TMP_HASH} | awk '{print $1}'`
}

# --- check hash against installed version ---
installed_hash_matches() {
    if [ -x /usr/local/bin/k3s ]; then
        HASH_INSTALLED=`sha256sum /usr/local/bin/k3s | awk '{print $1}'`
        if [ "${HASH_EXPECTED}" = "${HASH_INSTALLED}" ]; then
            return
        fi
    fi
    return 1
}

# --- download binary from github url ---
download_binary() {
    BIN_URL=${GITHUB_URL}/download/${INSTALL_K3S_VERSION}/k3s${SUFFIX}
    info "Downloading binary ${BIN_URL}"
    curl -o ${TMP_BIN} -sfL ${BIN_URL} || fatal "Binary download failed"
}

# --- verify downloaded binary hash ---
verify_binary() {
    info "Verifying binary download"
    HASH_BIN=`sha256sum ${TMP_BIN} | awk '{print $1}'`
    if [ "${HASH_EXPECTED}" != "${HASH_BIN}" ]; then
        fatal "Download sha256 does not match ${HASH_EXPECTED}, got ${HASH_BIN}"
    fi
}

# --- setup permissions and move binary to system directory ---
setup_binary() {
    chmod 755 ${TMP_BIN}
    info "Installing k3s to /usr/local/bin/k3s"
    $SUDO chown root:root ${TMP_BIN}
    $SUDO mv -f ${TMP_BIN} /usr/local/bin/k3s
}

# --- download and verify k3s ---
download_and_verify() {
    if can_skip_download; then
       info "Skipping k3s download and verify"
       verify_k3s_is_executable
       return
    fi

    setup_verify_arch
    verify_curl
    setup_tmp
    get_release_version
    download_hash

    if installed_hash_matches; then
        info "Skipping binary downloaded, installed k3s matches hash"
        return
    fi

    download_binary
    verify_binary
    setup_binary
}

# --- add additional utility links ---
create_symlinks() {
    if [ ! -e /usr/local/bin/kubectl ]; then
        info "Creating /usr/local/bin/kubectl symlink to k3s"
        $SUDO ln -s k3s /usr/local/bin/kubectl
    fi

    if [ ! -e /usr/local/bin/crictl ]; then
        info "Creating /usr/local/bin/crictl symlink to k3s"
        $SUDO ln -s k3s /usr/local/bin/crictl
    fi
}

# --- create uninstall script ---
create_uninstall() {
    UNINSTALL=/usr/local/bin/${UNINSTALL_K3S_SH}
    info "Creating uninstall script ${UNINSTALL}"
    $SUDO tee ${UNINSTALL} >/dev/null << EOF
#!/bin/sh
set -x
systemctl kill ${SYSTEMD_NAME}
systemctl disable ${SYSTEMD_NAME}
systemctl reset-failed ${SYSTEMD_NAME}
systemctl daemon-reload
rm -f /etc/systemd/system/${SERVICE_K3S}
rm -f /etc/systemd/system/${SERVICE_K3S}.env

remove_uninstall() {
    rm -f ${UNINSTALL}
}
trap remove_uninstall EXIT

if ls /etc/systemd/system/k3s*.service >/dev/null 2>&1; then
    set +x; echo "Additional k3s services installed, skipping uninstall of k3s"; set -x
    exit
fi

do_unmount() {
    MOUNTS=\`cat /proc/self/mounts | awk '{print \$2}' | grep "^\$1"\`
    if [ -n "\${MOUNTS}" ]; then
        umount \${MOUNTS}
    fi
}
do_unmount '/run/k3s'
do_unmount '/var/lib/rancher/k3s'

nets=\$(ip link show master cni0 | grep cni0 | awk -F': ' '{print \$2}' | sed -e 's|@.*||')
for iface in \$nets; do
    ip link delete \$iface;
done
ip link delete cni0
ip link delete flannel.1

if [ -L /usr/local/bin/kubectl ]; then
    rm -f /usr/local/bin/kubectl
fi
if [ -L /usr/local/bin/crictl ]; then
    rm -f /usr/local/bin/crictl
fi

rm -rf /etc/rancher/k3s
rm -rf /var/lib/rancher/k3s
rm -f /usr/local/bin/k3s
EOF
    $SUDO chmod 755 ${UNINSTALL}
    $SUDO chown root:root ${UNINSTALL}
}

# --- capture current env and create file containing k3s_ variables ---
create_env_file() {
    info "systemd: Creating environment file /etc/systemd/system/${SERVICE_K3S}.env"
    UMASK=`umask`
    umask 0377
    env | grep '^K3S_' | $SUDO tee /etc/systemd/system/${SERVICE_K3S}.env >/dev/null
    umask $UMASK
}

# --- write service file ---
create_service_file() {
    info "systemd: Creating service file /etc/systemd/system/${SERVICE_K3S}"
    $SUDO tee /etc/systemd/system/${SERVICE_K3S} >/dev/null << EOF
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
After=network.target

[Service]
Type=${INSTALL_K3S_TYPE}
EnvironmentFile=/etc/systemd/system/${SERVICE_K3S}.env
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s ${INSTALL_K3S_EXEC}
KillMode=process
Delegate=yes
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
}

# --- enable and start systemd service ---
systemd_enable_and_start() {
    info "systemd: Enabling ${SYSTEMD_NAME} unit"
    $SUDO systemctl enable ${SYSTEMD_NAME} >/dev/null
    $SUDO systemctl daemon-reload >/dev/null

    info "systemd: Starting ${SYSTEMD_NAME}"
    $SUDO systemctl restart ${SYSTEMD_NAME}
}

# --- run the install process --
{
    verify_systemd
    setup_env $@
    download_and_verify
    create_symlinks
    create_uninstall
    create_env_file
    create_service_file
    systemd_enable_and_start
}
