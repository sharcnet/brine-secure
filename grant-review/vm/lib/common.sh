# Shared helpers for the brine-review admin scripts. Installed root:root 0644 at
# /usr/local/lib/brine-review/common.sh and sourced, never run.
# shellcheck shell=bash

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: '&' in ${x//a/b} means the match

CONF=/etc/brine-review/review.conf
SRV=/srv/review

die() { echo "error: $*" >&2; exit 1; }
log() { logger -t brine-review -- "$*"; echo "$*"; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -r $CONF ]] || die "$CONF missing: run configure first"
# shellcheck source=/dev/null
source "$CONF"

valid_user() { [[ ${1:-} =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; }
valid_file() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$ ]]; }
is_reviewer() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx reviewers; }

need_reviewer() {
  valid_user "${1:-}" || die "bad username: ${1:-}"
  is_reviewer "$1" || die "$1 is not a reviewer"
}

# Replace @NAME@ placeholders with shell built-ins only, so values (keys included) never
# appear in a process's arguments. Usage: render [--partial] <template-file> NAME=value ...
# Without --partial, any @NAME@ left over is an error.
render() {
  local out pair tmpl partial=false
  [[ $1 == --partial ]] && { partial=true; shift; }
  tmpl=$1; shift
  out="$(< "$tmpl")"
  for pair in "$@"; do out="${out//@${pair%%=*}@/${pair#*=}}"; done
  $partial || [[ ! $out =~ @[A-Z_]+@ ]] || die "unfilled placeholder in $tmpl"
  printf '%s\n' "$out"
}

# Regenerate a reviewer's checksum manifest from what is actually in their originals.
write_manifest() {
  local u=$1 dir=$SRV/originals/$1
  if compgen -G "$dir/*" >/dev/null; then
    ( cd "$dir" && sha256sum -- * ) > "$SRV/manifests/$u.sha256"
  else
    : > "$SRV/manifests/$u.sha256"
  fi
  chmod 0600 "$SRV/manifests/$u.sha256"
}

# Write (or rewrite) a reviewer's runtime units: tmpfiles for the brine and web socket
# directories, and the Quadlet container unit. Prints "changed" if the container unit changed,
# so callers know to restart it. The web unit is a template (review-web@.service) and is
# pulled in by the container unit's Wants=.
write_units() {
  local u=$1 unit=/etc/containers/systemd/review-$1.container new
  printf 'd /run/brine-proxy/%s 0755 root root -\nd /run/review-web/%s 0711 root root -\n' "$u" "$u" \
    > "/etc/tmpfiles.d/brine-review-$u.conf"
  chmod 0644 "/etc/tmpfiles.d/brine-review-$u.conf"
  rm -f "/etc/tmpfiles.d/brine-proxy-$u.conf"           # older name
  # Only create: tmpfiles would reset /run/review-web/<u> to root, undoing review-own-home.
  [[ -d /run/brine-proxy/$u && -d /run/review-web/$u ]] || systemd-tmpfiles --create "/etc/tmpfiles.d/brine-review-$u.conf"
  new=$(render /etc/brine-review/review.container.tmpl "USER=$u")
  if [[ ! -f $unit || $(< "$unit") != "$new" ]]; then
    printf '%s\n' "$new" > "$unit"; chmod 0644 "$unit"
    echo changed
  fi
}
