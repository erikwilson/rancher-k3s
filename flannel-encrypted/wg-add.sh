#!/usr/bin/env bash

# probe for any modules that may be needed
modprobe wireguard tun 2>/dev/null

# try wireguard kernel module first
ip link add "$1" type wireguard && exit

# try boringtun and let it drop privileges
/tmp/boringtun "$1" && exit

# try boringtun w/o dropping privileges
WG_SUDO=1 /tmp/boringtun "$1" && exit

# try wireguard-go
WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 /tmp/wireguard-go "$1" && exit

exit 1
