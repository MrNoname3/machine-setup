# shellcheck shell=bash disable=SC2034  # the variables are for the scripts that source this
# devices.sh — sourced. iotest_devices DIR sets the block devices under the
# filesystem that holds DIR:
#   IOTEST_SRC IOTEST_MNT     the filesystem's source device and mountpoint
#   IOTEST_FS IOTEST_FS_DEV   kernel name and major:minor of that device (dm-0,
#                             252:0); the jobs' io.stat lines are keyed by it
#   IOTEST_DISK IOTEST_DISK_DEV  the physical disk underneath (nvme0n1, 259:0)
#   IOTEST_CRYPT              device-mapper names of the dm-crypt layers between
iotest_devices() {
  IOTEST_SRC=$(findmnt -nvo SOURCE --target "$1")
  IOTEST_MNT=$(findmnt -no TARGET --target "$1")
  read -r IOTEST_FS IOTEST_FS_DEV < <(lsblk -ndro KNAME,MAJ:MIN "$IOTEST_SRC")
  read -r IOTEST_DISK IOTEST_DISK_DEV < <(lsblk -nrso KNAME,MAJ:MIN,TYPE "$IOTEST_SRC" | awk '$3 == "disk" {print $1, $2}' | tail -n 1)
  IOTEST_CRYPT=$(lsblk -nrso NAME,TYPE "$IOTEST_SRC" | awk '$2 == "crypt" {print $1}' | paste -sd' ')
}
