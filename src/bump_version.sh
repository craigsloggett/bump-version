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

# Label for the log. A bare token key is already readable; a yq path is not, so
# the YAML branch narrows it to the final key below.
label="${key}"

command -v awk >/dev/null 2>&1 || die "awk not found"

[ -f "${file}" ] || die "file not found: ${file}"
[ -w "${file}" ] || die "file not writable: ${file}"

changed=false

case "${file}" in
  *.yml | *.yaml)
    command -v yq >/dev/null 2>&1 || die "yq not found"

    # yq targets the path exactly, so no version-pattern inference is needed. A
    # missing simple path yields "null"; a path that traverses [] past a
    # non-matching node yields empty. Neither is a realistic version, so treat
    # both as no match and fail rather than write nothing and report success.
    current="$(yq "${key}" "${file}")"
    if [ -z "${current}" ] || [ "${current}" = "null" ]; then
      die "yq path matched nothing: ${key}"
    fi

    # Narrow the path to its final key for a readable log line.
    label="$(yq "(${key}) | key" "${file}")"

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
    # and carry no regex metacharacters. The value is taken as the assignment's
    # third field, so the caller must only target lines whose value is a version.
    status=0
    awk -v key="${key}" -v version="${version}" '
      BEGIN {
        assignment_operator = "[[:space:]]*:?="        # Optional spaces, := or =
        key_line_pattern = "^" key assignment_operator
      }
      !found && $0 ~ key_line_pattern {
        found = 1
        current = $3
        if (current != version) {
          # Splice over "current in place" so surrounding alignment survives.
          at = index($0, current)
          $0 = substr($0, 1, at - 1) version substr($0, at + length(current))
          changed = 1
        }
        print
        next
      }
      { print }
      END {
        if (!found) exit 2    # Key not found.
        exit changed ? 0 : 3  # 0 = changed, 3 = already current.
      }
    ' "${file}" >"${tmp}" || status=$?

    case "${status}" in
      0)
        mv "${tmp}" "${file}"
        changed=true
        ;;
      3) : ;; # Key found, already at version: nothing to do.
      2) die "key not found: ${key}" ;;
      *) die "awk failed with status ${status}" ;;
    esac
    ;;
esac

if [ "${changed}" = true ]; then
  printf 'updated %s to %s in %s\n' "${label}" "${version}" "${file}"
else
  printf '%s already at %s in %s\n' "${label}" "${version}" "${file}"
fi

[ -n "${GITHUB_OUTPUT:-}" ] && printf 'changed=%s\n' "${changed}" >>"${GITHUB_OUTPUT}"

exit 0
