#!/bin/sh
# make-media.sh [DIR]: the test clips, a minute of ffmpeg's testsrc2 pattern
# each, into DIR (default work/browser-test/media in this repository), and
# beside each its frame at 11.01 s as NAME.ref.png, which run.py's picture
# check compares the browser's picture with.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-${BT_STATE:-$here/../../work/browser-test}/media}
command -v ffmpeg >/dev/null || { echo "make-media.sh: needs ffmpeg" >&2; exit 1; }
mkdir -p "$dir"
cd "$dir"
clip() { # clip <name> <size> <rate> <encoder options...>
  name=$1 size=$2 rate=$3
  shift 3
  [ -s "$name" ] || ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=$size:rate=$rate:duration=60" "$@" "$name"
  # untagged HD video, which browsers convert to RGB as BT.709
  [ -s "$name.ref.png" ] || ffmpeg -loglevel error -y -ss 11.01 -i "$name" -frames:v 1 -update 1 \
    -vf scale=in_color_matrix=bt709:in_range=tv:out_range=pc "$name.ref.png"
}
h264='-c:v libx264 -profile:v high -pix_fmt yuv420p'
# shellcheck disable=SC2086 # $h264 is a list of options
{
  clip h264-1080.mp4 1920x1080 30 $h264 -b:v 6M
  clip h264-1080-25.mp4 1920x1080 25 $h264 -b:v 6M
  clip h264-1080-60.mp4 1920x1080 60 $h264 -b:v 8M
  clip h264-720.mp4 1280x720 30 $h264 -b:v 3M
}
clip vp9-1080.webm 1920x1080 30 -c:v libvpx-vp9 -b:v 4M -deadline realtime -cpu-used 8 -row-mt 1
ls -l "$dir"
