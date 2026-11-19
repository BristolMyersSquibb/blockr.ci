#!/usr/bin/env bash
# Decides whether pak may call apt when it installs the lockfile LOCKFILE,
# by writing its settings to GITHUB_ENV for the steps that follow.
#
# The image holds the system packages of the repos it is built for.  When
# none of those in the lockfile is missing, the install runs with the
# system requirements of pak switched off.  Left on, pak runs apt-get
# update, and on CI it reinstalls every system package that the lockfile
# names, installed or not.  When some are missing, pak installs those, and
# only those.
#
# Env vars: LOCKFILE, GITHUB_ENV

set -euo pipefail
export LC_ALL=C

needed=$(jq -r '.sysreqs.packages // [] | .[]' "$LOCKFILE" | sed '/^$/d' | sort -u)

# A package counts as installed, under its own name and under each name it
# provides, when the second letter of its status is i.
installed=$(dpkg-query -W -f '${db:Status-Abbrev}\t${Package}\t${Provides}\n' |
  awk -F '\t' '$1 ~ /^.i/ {
    print $2
    n = split($3, names, /, */)
    for (i = 1; i <= n; i++) {
      sub(/ .*/, "", names[i])
      if (names[i] != "") print names[i]
    }
  }' | sort -u)

if [ -z "$needed" ]; then
  echo "These dependencies need no system packages."
  echo "PKG_SYSREQS=false" >> "$GITHUB_ENV"
  exit 0
fi

missing=$(comm -23 <(printf '%s\n' "$needed") <(printf '%s\n' "$installed"))

if [ -z "$missing" ]; then
  echo "The image holds all $(printf '%s\n' "$needed" | wc -l) system packages that these dependencies need, so pak installs with its system requirements switched off."
  echo "Then pak no longer looks them up, and lists them all as missing."
  echo "PKG_SYSREQS=false" >> "$GITHUB_ENV"
else
  echo "::warning title=System packages missing from the image::This job installs them with apt: $(printf '%s\n' "$missing" | paste -sd ' ' -)"
  {
    echo "PKG_SYSREQS=true"
    echo "PKG_SYSREQS_UPDATE=false"
  } >> "$GITHUB_ENV"
fi
