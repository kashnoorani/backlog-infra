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

# Check SSH connectivity to GitHub. Critical for cloning, pulling, and pushing.
# $1 = timeout in seconds (default 5). Returns 0 if healthy, non-zero if broken.
check_github_ssh() {
  local timeout="${1:-5}"
  local out
  out="$(ssh -o ConnectTimeout="$timeout" -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)" || true
  if echo "$out" | grep -qi "successfully authenticated"; then
    return 0
  fi
  return 1
}

# Diagnostic helper: if SSH to GitHub is broken, print actionable steps and
# return 1. Callers use this before operations that need GitHub access, passing
# the command name for the error header.
need_github_ssh() {
  local caller="${1:-$(basename "$0")}"
  if check_github_ssh; then
    return 0
  fi
  echo >&2
  echo "================================================================================" >&2
  echo "  SSH TO GITHUB IS BROKEN" >&2
  echo "  $caller requires SSH access to GitHub." >&2
  echo "================================================================================" >&2
  echo >&2
  echo "  Quick fix:" >&2
  echo "    1. Generate a key (if you don't have one):" >&2
  echo "       ssh-keygen -t ed25519 -C \"your-email@example.com\"" >&2
  echo >&2
  echo "    2. Start the SSH agent and add the key:" >&2
  echo "       eval \"\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519" >&2
  echo >&2
  echo "    3. Copy the public key:" >&2
  echo "       pbcopy < ~/.ssh/id_ed25519.pub" >&2
  echo >&2
  echo "    4. Add it to GitHub:" >&2
  echo "       https://github.com/settings/ssh" >&2
  echo >&2
  echo "    5. Verify:" >&2
  echo "       ssh -T git@github.com" >&2
  echo >&2
  echo "================================================================================" >&2
  return 1
}
