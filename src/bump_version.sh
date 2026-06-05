#!/bin/sh
# Rewrites a single pinned version string in a file while preserving every other
# byte. Locating the version differs by file type, a yq path for YAML or a leading
# key token otherwise, but both resolve to the same (line, value) pair and a single
# splice rewrites that value in place. The consumer resolves the desired version
# and passes it in; this script only performs the edit.
set -euf

die() {
  printf '%s\n' "bump-version: $1" >&2
  exit 1
}

: "${INPUT_FILE:?file input is required}"
: "${INPUT_KEY:?key input is required}"
: "${INPUT_VERSION:?version input is required}"

command -v awk >/dev/null 2>&1 || die "awk not found"

# locate_yaml resolves the key (a yq path) against the file to a "LINE VALUE" pair
# on stdout, returning non-zero if the path matches nothing.
locate_yaml() (
  # A missing simple path yields "null"; a path that traverses [] past a
  # non-matching node yields empty. Neither is a realistic version, so treat both
  # as no match rather than locate nothing and report success.
  current="$(yq "${key}" "${file}")"
  if [ -z "${current}" ] || [ "${current}" = "null" ]; then
    return 2
  fi

  # yq numbers lines from the first content node, ignoring any leading blank lines,
  # comments, or document markers, so its reported line is short by that count. Add
  # the number of skipped leading lines back to recover the true file line.
  offset="$(
    awk '
      BEGIN {
        blank_line      = "^[[:space:]]*$"
        comment_line    = "^[[:space:]]*#"
        document_marker = "^---"
        directive       = "^%"
      }
      $0 ~ blank_line ||
      $0 ~ comment_line ||
      $0 ~ document_marker ||
      $0 ~ directive {
        next
      }
      { print NR - 1; exit }
    ' "${file}"
  )"
  line="$(yq "(${key}) | line" "${file}")"

  printf '%s %s\n' "$((line + offset))" "${current}"
)

# locate_keyed resolves the key against the file to a "LINE VALUE" pair on stdout
# by matching the first "KEY := value" assignment, returning non-zero if no such
# assignment is present.
locate_keyed() (
  # The key is dynamic, so it is passed via -v; keys in scope are [A-Za-z0-9_-]
  # and carry no regex metacharacters. The value is the assignment's third field,
  # so the caller must only target lines whose value is a version.
  awk -v key="${key}" '
    BEGIN {
      assignment_operator = "[[:space:]]*:?="
      key_line_pattern = "^" key assignment_operator
    }
    $0 ~ key_line_pattern {
      printf "%d %s\n", NR, $3
      found = 1
      exit
    }
    END { if (!found) exit 2 }
  ' "${file}"
)

# splice rewrites OLD to NEW on the given line of the file in place, leaving every
# other byte (blank lines, comments, alignment) untouched. The staged temp and
# atomic mv land the change only after a clean rewrite, and a non-zero return
# means OLD was not present on that line.
splice() (
  line="$1"
  old="$2"
  new="$3"

  temporary="$(mktemp "$(dirname "${file}")/.bump-version.XXXXXX")"
  readonly temporary
  trap 'rm -f "${temporary}"' EXIT INT TERM HUP

  # Splice over OLD in place so leading indentation, the key, and any trailing
  # inline comment on the line all survive.
  awk -v line="${line}" -v old="${old}" -v new="${new}" '
    NR == line {
      at = index($0, old)
      if (at == 0) exit 2
      $0 = substr($0, 1, at - 1) new substr($0, at + length(old))
      print
      next
    }
    { print }
  ' "${file}" >"${temporary}" || return 2

  mv "${temporary}" "${file}"
)

main() {
  file="${INPUT_FILE}"
  key="${INPUT_KEY}"
  version="${INPUT_VERSION}"

  [ -f "${file}" ] || die "file not found: ${file}"
  [ -w "${file}" ] || die "file not writable: ${file}"

  case "${file}" in
    *.yml | *.yaml)
      command -v yq >/dev/null 2>&1 || die "yq not found"
      # The splice edits a single line, so a multi-node match is ambiguous.
      [ "$(yq "[${key}] | length" "${file}")" -le 1 ] ||
        die "key matched multiple lines: ${key}"
      target="$(locate_yaml)" || die "key matched nothing: ${key}"
      ;;
    *)
      target="$(locate_keyed)" || die "key not found: ${key}"
      ;;
  esac

  line="${target%% *}"
  current="${target#* }"

  changed=false
  if [ "${current}" != "${version}" ]; then
    splice "${line}" "${current}" "${version}" ||
      die "expected ${current} on line ${line} of ${file}"
    changed=true
  fi

  if [ "${changed}" = true ]; then
    printf 'Updated %s to %s\n' "${file}" "${version}"
  else
    printf '%s already at %s\n' "${file}" "${version}"
  fi

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'changed=%s\n' "${changed}" >>"${GITHUB_OUTPUT}"
    printf 'file=%s\n' "${file}" >>"${GITHUB_OUTPUT}"
  fi

  # Convenience: accumulate the file in a job-scoped list a step summary can cat.
  # RUNNER_TEMP is shared across a job, so multiple bumps build one Markdown list.
  if [ "${changed}" = true ] && [ -n "${RUNNER_TEMP:-}" ]; then
    # shellcheck disable=SC2016 # Backticks are a literal Markdown code-span, not a subshell.
    printf -- '- `%s`\n' "${file}" >>"${RUNNER_TEMP}/changed-files.md"
  fi
}

main "$@"
