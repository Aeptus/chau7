#!/bin/sh
# Fake C compiler for macOS type-checking on Linux: creates the output file
# only. -E prints the input files (enough for cc-rs compiler detection).
out=""; pre=0; files=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -o*) out="${1#-o}" ;;
    -E) pre=1 ;;
    --version|-v|-dumpversion) echo "clang version 17.0.0"; exit 0 ;;
    -*) ;;
    *) files="$files $1" ;;
  esac
  shift
done
if [ "$pre" = 1 ]; then
  for f in $files; do [ -f "$f" ] && cat "$f"; done
  exit 0
fi
[ -n "$out" ] && : > "$out"
exit 0
