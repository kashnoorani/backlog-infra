# _lib.sh — shared helpers sourced by backlog-infra/bin scripts.
# Source this at the top of each script (after set -euo pipefail):
#   LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$LIB_DIR/_lib.sh"

# Human-readable age string from seconds-since-epoch diff.
fmt_age() {
  local d=$1
  if   (( d < 60 ));    then printf '%ds ago' "$d"
  elif (( d < 3600 ));  then printf '%dm ago' $((d/60))
  elif (( d < 86400 )); then printf '%dh ago' $((d/3600))
  else                       printf '%dd ago' $((d/86400))
  fi
}

# Human-readable token count (abbreviates thousands as "k", millions as "M").
fmt_tok() {
  local n=$1
  if   (( n < 1000 ));    then printf '%d' "$n"
  elif (( n < 1000000 )); then awk -v n=$n 'BEGIN{printf "%.1fk", n/1000}'
  else                         awk -v n=$n 'BEGIN{printf "%.1fM", n/1000000}'
  fi
}

# XML-escape a string for safe interpolation into a plist heredoc.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}
