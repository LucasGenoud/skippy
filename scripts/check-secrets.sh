#!/bin/sh

# Lightweight repository guard for high-confidence secrets. It intentionally
# reports paths only so a CI failure cannot echo a credential into build logs.
set -eu

status=0

# The patterns below are spelled out in this file, so scanning it would report
# the scanner every time. Its own path stays out of every content scan.
self=':(exclude)scripts/check-secrets.sh'

check_paths() {
  matches=$(git ls-files | grep -E "$1" || true)
  if [ -n "$matches" ]; then
    echo "Potential credential file tracked by Git:"
    echo "$matches" | sed 's/^/  /'
    status=1
  fi
}

check_content() {
  matches=$(git grep -IlE "$1" -- . "$self" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    echo "Potential secret pattern found in tracked files:"
    echo "$matches" | sed 's/^/  /'
    status=1
  fi
}

check_content_ci() {
  matches=$(git grep -IlEi "$1" -- . "$self" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    echo "Potential secret pattern found in tracked files:"
    echo "$matches" | sed 's/^/  /'
    status=1
  fi
}

check_paths '(^|/)(\.env($|\.)|credentials[^/]*\.json$|secrets?[^/]*\.(json|ya?ml)$|service-account[^/]*\.json$|google-services\.json$|GoogleService-Info\.plist$|.*\.(pem|key|p12|pfx|jks|keystore|mobileprovision|provisionprofile|bak|backup|dump)$|.*\.(db|sqlite|sqlite3)(-.*)?$)'

check_content 'BEGIN (RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY'
check_aws_content() {
  files=$(git grep -IlE 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}' -- . "$self" 2>/dev/null || true)
  for file in $files; do
    values=$(git grep -h -oE 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}' -- "$file" 2>/dev/null || true)
    for value in $values; do
      # AWS publishes this exact SigV4 fixture in its documentation and the
      # repository uses it only for a deterministic signing test.
      case "$value" in
        AKIAIOSFODNN7EXAMPLE) ;;
        *)
          echo "Potential secret pattern found in tracked files:"
          echo "  $file"
          status=1
          break
          ;;
      esac
    done
  done
}

check_aws_content
check_content '(ghp|gho|ghs|github_pat|glpat)-[A-Za-z0-9_-]+'
check_content 'xox[baprs]-[A-Za-z0-9-]+'
check_content 'AIza[0-9A-Za-z_-]{20,}'
check_content '(sk_live_|rk_live_|sk-proj-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,})'
check_content 'npm_[A-Za-z0-9]{20,}'
check_content_ci '(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9/+_=.-]{16,}["'"'"']'

if [ "$status" -ne 0 ]; then
  echo "Secret check failed. Remove the data from the tracked tree and rotate any exposed credential."
  exit 1
fi

echo "Secret check passed."
