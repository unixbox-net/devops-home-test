#!/bin/bash
# Central environment defaults for all modules

: "${ISO_ORIG:=/root/debian-13.1.0-amd64-netinst.iso}"
: "${BUILD_DIR:=/root/debian-iso}"
: "${CUSTOM_DIR:=$BUILD_DIR/custom}"
: "${MOUNT_DIR:=/mnt/iso}"
: "${DARKSITE_DIR:=$CUSTOM_DIR/darksite}"
: "${OUTPUT_ISO:=$BUILD_DIR/darksite-custom.iso}"
: "${FINAL_ISO:=/root/final-darksite.iso}"
: "${PROXMOX_HOST:=10.100.10.225}"
