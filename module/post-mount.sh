#!/system/bin/sh
# OnePlus Camera for LineageOS - after the metamodule has mounted the module files (KernelSU's
# post-mount stage, before zygote and the camera HAL start): mount the camera app's own libraries
# and models from the module folder (common.sh, mount_blobs).
MODDIR=${0%/*}

. "$MODDIR/common.sh"

mount_blobs "$MODDIR"
