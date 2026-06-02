#!/bin/sh
# Rewrites a single pinned version string in a file. YAML files are edited by yq
# path expression; all other files match the version-bearing line by a leading
# key token and swap the version-looking token on it. The consumer resolves the
# desired version and passes it in; this script only performs the edit.
set -euf

die() {
  printf '%s\n' "bump-version: $1" >&2
  exit 1
}

file="${INPUT_FILE:?file input is required}"
key="${INPUT_KEY:?key input is required}"
version="${INPUT_VERSION:?version input is required}"

command -v awk >/dev/null 2>&1 || die "awk not found"

[ -f "${file}" ] || die "file not found: ${file}"
[ -w "${file}" ] || die "file not writable: ${file}"

changed=false

case "${file}" in
  *.yml | *.yaml)
    command -v yq >/dev/null 2>&1 || die "yq not found"

    # yq targets the path exactly, so no version-pattern inference is needed. A
    # missing path yields "null", which is not a realistic version value.
    current="$(yq "${key}" "${file}")"
    [ "${current}" != "null" ] || die "yq path matched nothing: ${key}"

    if [ "${current}" != "${version}" ]; then
      # Pass the value via the environment so it is treated as a string and
      # never spliced into the yq expression.
      VERSION="${version}" yq -i "${key} = strenv(VERSION)" "${file}"
      changed=true
    fi
    ;;
  *)
    # Stage the rewrite in the target's directory so the mv is atomic, then
    # commit it only on a clean replacement.
    dir="$(dirname "${file}")"
    tmp="$(mktemp "${dir}/.bump-version.XXXXXX")"
    trap 'rm -f "${tmp}"' EXIT INT TERM HUP

    # The key is dynamic, so it is passed via -v; keys in scope are [A-Za-z0-9_-]
    # and carry no regex metacharacters. The version pattern is constant, so it
    # stays a /regex/ literal to avoid -v string-escape surprises.
    status=0
    awk -v key="${key}" -v version="${version}" '
      BEGIN { keyre = "^[[:space:]]*" key "([[:space:]]|:|=)" }  # Key begins the value-bearing line.
      !found && $0 ~ keyre {
        found = 1
        output = $0
        if (sub(/v?[0-9]+\.[0-9]+\.[0-9]+/, version, output) == 0) {
          no_version = 1                                         # Key line carried no version token.
          print
          next
        }
        if (output != $0) changed = 1                           # Replacement differed: a real bump.
        print output
        next
      }
      { print }                                                 # Passthrough for every other line.
      END {
        if (!found)     exit 2                                  # Key not found.
        if (no_version) exit 4                                  # Key found, but no version on its line.
        exit changed ? 0 : 3                                    # 0 = changed, 3 = already current.
      }
    ' "${file}" >"${tmp}" || status=$?

    case "${status}" in
      0)
        mv "${tmp}" "${file}"
        changed=true
        ;;
      3) : ;; # Key found, already at version: nothing to do.
      2) die "key not found: ${key}" ;;
      4) die "no version token on line for key: ${key}" ;;
      *) die "awk failed with status ${status}" ;;
    esac
    ;;
esac

[ -n "${GITHUB_OUTPUT:-}" ] && printf 'changed=%s\n' "${changed}" >>"${GITHUB_OUTPUT}"

exit 0
