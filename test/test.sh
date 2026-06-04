#!/bin/sh
# Functional tests for src/bump_version.sh. Each case drives the real script as a
# subprocess against a throwaway fixture and asserts on exit status, captured output,
# and resulting file contents. Pure POSIX, no test framework: run with `sh test/test.sh`.
set -euf

command -v yq >/dev/null 2>&1 || {
  printf '%s\n' "test: yq not found; it is required for the YAML cases" >&2
  exit 1
}

# run invokes the script with the given file, key, and version, capturing combined
# stdout and stderr to ${output} and the exit status to ${status}. GITHUB_OUTPUT is
# pointed at a fresh ${gho} so the `changed` line can be asserted per case.
run() {
  : "run file=$1 key=$2 version=$3"
  : >"${gho}"
  status=0
  INPUT_FILE="$1" INPUT_KEY="$2" INPUT_VERSION="$3" GITHUB_OUTPUT="${gho}" \
    "${script}" >"${output}" 2>&1 || status=$?
}

# pass records a passing assertion and prints a PASS line.
pass() {
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$1"
}

# fail records a failing assertion and prints a FAIL line with optional detail.
fail() {
  failed=$((failed + 1))
  printf 'FAIL: %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '      %s\n' "$2"
  fi
}

# assert_status checks the last run exited with the expected status.
assert_status() {
  a_expected="$1"
  a_name="$2"
  if [ "${status}" -eq "${a_expected}" ]; then
    pass "${a_name}"
  else
    fail "${a_name}" "expected status ${a_expected}, got ${status}"
  fi
}

# assert_failed checks the last run exited non-zero, without pinning the exact code.
assert_failed() {
  a_name="$1"
  if [ "${status}" -ne 0 ]; then
    pass "${a_name}"
  else
    fail "${a_name}" "expected a non-zero exit status"
  fi
}

# assert_output_contains checks the captured output includes the given substring.
assert_output_contains() {
  a_needle="$1"
  a_name="$2"
  if grep -qF "${a_needle}" "${output}"; then
    pass "${a_name}"
  else
    fail "${a_name}" "output missing: ${a_needle}"
  fi
}

# assert_file_contains checks the named file includes the given substring.
assert_file_contains() {
  a_path="$1"
  a_needle="$2"
  a_name="$3"
  if grep -qF "${a_needle}" "${a_path}"; then
    pass "${a_name}"
  else
    fail "${a_name}" "file missing: ${a_needle}"
  fi
}

# assert_file_unchanged checks the file is byte-identical to its reference copy.
assert_file_unchanged() {
  a_path="$1"
  a_ref="$2"
  a_name="$3"
  if cmp -s "${a_path}" "${a_ref}"; then
    pass "${a_name}"
  else
    fail "${a_name}" "file changed unexpectedly"
  fi
}

# assert_single_line_change checks exactly one line differs from the reference copy.
assert_single_line_change() {
  a_path="$1"
  a_ref="$2"
  a_name="$3"
  a_changed="$(diff "${a_ref}" "${a_path}" | grep -c '^>' || :)"
  if [ "${a_changed}" -eq 1 ]; then
    pass "${a_name}"
  else
    fail "${a_name}" "expected 1 changed line, got ${a_changed}"
  fi
}

# test_yaml_bump rewrites a pinned YAML value addressed by a yq path.
test_yaml_bump() {
  : "case: yaml bump"
  file="${work}/deps.yml"
  cat >"${file}" <<'EOF'
tools:
  formatter:
    version: 1.0.0
EOF
  run "${file}" '.tools.formatter.version' '2.0.0'
  assert_status 0 'yaml bump: exits zero'
  assert_output_contains 'Updated' 'yaml bump: reports updated'
  assert_file_contains "${file}" 'version: 2.0.0' 'yaml bump: new value written'
  assert_file_contains "${gho}" 'changed=true' 'yaml bump: changed=true'
}

# test_yaml_idempotent leaves a file untouched when it already holds the version.
test_yaml_idempotent() {
  : "case: yaml idempotent"
  file="${work}/deps_same.yml"
  cat >"${file}" <<'EOF'
tools:
  formatter:
    version: 1.0.0
EOF
  reference="${work}/deps_same.ref"
  cp "${file}" "${reference}"
  run "${file}" '.tools.formatter.version' '1.0.0'
  assert_status 0 'yaml idempotent: exits zero'
  assert_output_contains 'already at' 'yaml idempotent: reports already at'
  assert_file_contains "${gho}" 'changed=false' 'yaml idempotent: changed=false'
  assert_file_unchanged "${file}" "${reference}" 'yaml idempotent: file untouched'
}

# test_keyed_bump rewrites a keyed assignment, preserving alignment and an inline comment.
test_keyed_bump() {
  : "case: keyed bump"
  file="${work}/Makefile"
  cat >"${file}" <<'EOF'
GO_VERSION       := 1.22.0
GOLANGCI_VERSION := 1.59.0  # pinned
EOF
  reference="${work}/Makefile.ref"
  cp "${file}" "${reference}"
  run "${file}" 'GOLANGCI_VERSION' '1.60.0'
  assert_status 0 'keyed bump: exits zero'
  assert_output_contains 'Updated' 'keyed bump: reports updated'
  assert_file_contains "${file}" 'GOLANGCI_VERSION := 1.60.0  # pinned' \
    'keyed bump: alignment and comment preserved'
  assert_file_contains "${gho}" 'changed=true' 'keyed bump: changed=true'
  assert_single_line_change "${file}" "${reference}" 'keyed bump: only one line changed'
}

# test_keyed_idempotent leaves a keyed file untouched when already at the version.
test_keyed_idempotent() {
  : "case: keyed idempotent"
  file="${work}/Makefile_same"
  cat >"${file}" <<'EOF'
GOLANGCI_VERSION := 1.59.0
EOF
  reference="${work}/Makefile_same.ref"
  cp "${file}" "${reference}"
  run "${file}" 'GOLANGCI_VERSION' '1.59.0'
  assert_status 0 'keyed idempotent: exits zero'
  assert_output_contains 'already at' 'keyed idempotent: reports already at'
  assert_file_contains "${gho}" 'changed=false' 'keyed idempotent: changed=false'
  assert_file_unchanged "${file}" "${reference}" 'keyed idempotent: file untouched'
}

# test_keyed_plain_assignment rewrites a "KEY = value" assignment, the plain-equals
# form documented alongside ":=".
test_keyed_plain_assignment() {
  : "case: keyed plain assignment"
  file="${work}/config.mk"
  cat >"${file}" <<'EOF'
KEY = 1.0.0
EOF
  reference="${work}/config.mk.ref"
  cp "${file}" "${reference}"
  run "${file}" 'KEY' '2.0.0'
  assert_status 0 'keyed plain: exits zero'
  assert_output_contains 'Updated' 'keyed plain: reports updated'
  assert_file_contains "${file}" 'KEY = 2.0.0' 'keyed plain: new value written'
  assert_file_contains "${gho}" 'changed=true' 'keyed plain: changed=true'
  assert_single_line_change "${file}" "${reference}" 'keyed plain: only one line changed'
}

# test_preserves_bytes confirms only the version token changes, leaving indentation
# and an inline comment on the version line byte-for-byte intact.
test_preserves_bytes() {
  : "case: preserve bytes"
  file="${work}/preserve.yml"
  cat >"${file}" <<'EOF'
tools:
  formatter:
    version: 1.0.0  # keep me
EOF
  reference="${work}/preserve.ref"
  cp "${file}" "${reference}"
  run "${file}" '.tools.formatter.version' '2.0.0'
  assert_status 0 'preserve bytes: exits zero'
  assert_file_contains "${file}" '    version: 2.0.0  # keep me' \
    'preserve bytes: indentation and inline comment kept'
  assert_single_line_change "${file}" "${reference}" 'preserve bytes: only one line changed'
}

# test_yaml_no_full_rewrite guards against the splice being replaced by a normalizing
# rewrite (e.g. `yq -i`). The fixture carries comments, a blank line, and a second key
# that a full-document rewrite would reflow or strip, so anything beyond the single
# targeted line changing trips assert_single_line_change.
test_yaml_no_full_rewrite() {
  : "case: yaml no full rewrite"
  file="${work}/document.yml"
  cat >"${file}" <<'EOF'
tools:
  formatter:
    version: 1.0.0  # keep me

  linter:
    version: 2.3.4  # and me
# Trailing note.
EOF
  reference="${work}/document.ref"
  cp "${file}" "${reference}"
  run "${file}" '.tools.formatter.version' '2.0.0'
  assert_status 0 'no full rewrite: exits zero'
  assert_file_contains "${file}" '# Trailing note.' 'no full rewrite: trailing comment kept'
  assert_single_line_change "${file}" "${reference}" 'no full rewrite: only one line changed'
}

# test_yaml_leading_comment rewrites the version in a YAML file that opens with a comment,
# asserting the matched line is the one rewritten while every other byte is preserved.
test_yaml_leading_comment() {
  : "case: yaml leading comment"
  file="${work}/leading.yml"
  cat >"${file}" <<'EOF'
# Pinned tool versions.
tools:
  formatter:
    version: 1.0.0
EOF
  reference="${work}/leading.ref"
  cp "${file}" "${reference}"
  run "${file}" '.tools.formatter.version' '2.0.0'
  assert_status 0 'leading comment: exits zero'
  assert_file_contains "${file}" 'version: 2.0.0' 'leading comment: new value written'
  assert_single_line_change "${file}" "${reference}" 'leading comment: only one line changed'
}

# test_yaml_no_match fails when the yq path resolves to nothing.
test_yaml_no_match() {
  : "case: yaml no match"
  file="${work}/nomatch.yml"
  cat >"${file}" <<'EOF'
tools:
  formatter:
    version: 1.0.0
EOF
  run "${file}" '.tools.linter.version' '2.0.0'
  assert_failed 'yaml no match: exits non-zero'
  assert_output_contains 'key matched nothing' 'yaml no match: reports nothing matched'
}

# test_yaml_empty_match fails when the yq path traverses an empty sequence, yielding
# empty output rather than "null".
test_yaml_empty_match() {
  : "case: yaml empty match"
  file="${work}/empty.yml"
  cat >"${file}" <<'EOF'
services: []
EOF
  run "${file}" '.services[].image' '2.0.0'
  assert_failed 'yaml empty match: exits non-zero'
  assert_output_contains 'key matched nothing' 'yaml empty match: reports nothing matched'
}

# test_yaml_multi_match fails when the yq path resolves to more than one line.
test_yaml_multi_match() {
  : "case: yaml multi match"
  file="${work}/multi.yml"
  cat >"${file}" <<'EOF'
services:
  - image: 1.0.0
  - image: 1.0.0
EOF
  run "${file}" '.services[].image' '2.0.0'
  assert_failed 'yaml multi match: exits non-zero'
  assert_output_contains 'key matched multiple lines' 'yaml multi match: reports multiple lines'
}

# test_keyed_not_found fails when no assignment begins with the key.
test_keyed_not_found() {
  : "case: keyed not found"
  file="${work}/Makefile_missing"
  cat >"${file}" <<'EOF'
GO_VERSION := 1.22.0
EOF
  run "${file}" 'MISSING_VERSION' '2.0.0'
  assert_failed 'keyed not found: exits non-zero'
  assert_output_contains 'key not found' 'keyed not found: reports key not found'
}

# test_file_not_found fails when the target file does not exist.
test_file_not_found() {
  : "case: file not found"
  run "${work}/does_not_exist.txt" 'KEY' '2.0.0'
  assert_failed 'file not found: exits non-zero'
  assert_output_contains 'file not found' 'file not found: reports missing file'
}

# test_missing_input fails when a required input is unset.
test_missing_input() {
  : "case: missing input"
  file="${work}/missing_input.txt"
  printf '%s\n' 'KEY = 1.0.0' >"${file}"
  : >"${gho}"
  status=0
  INPUT_FILE="${file}" INPUT_KEY='KEY' GITHUB_OUTPUT="${gho}" \
    "${script}" >"${output}" 2>&1 || status=$?
  assert_failed 'missing input: exits non-zero'
  assert_output_contains 'version input is required' 'missing input: reports required input'
}

main() {
  here="$(cd "$(dirname "$0")" && pwd)"
  script="${here}/../src/bump_version.sh"
  [ -f "${script}" ] || {
    printf '%s\n' "test: script not found: ${script}" >&2
    exit 1
  }

  work="$(mktemp -d)"
  readonly work
  trap 'rm -rf "${work}"' EXIT INT TERM HUP

  passed=0
  failed=0
  output="${work}/output"
  gho="${work}/github_output"
  status=0

  test_yaml_bump
  test_yaml_idempotent
  test_keyed_bump
  test_keyed_idempotent
  test_keyed_plain_assignment
  test_preserves_bytes
  test_yaml_no_full_rewrite
  test_yaml_leading_comment
  test_yaml_no_match
  test_yaml_empty_match
  test_yaml_multi_match
  test_keyed_not_found
  test_file_not_found
  test_missing_input

  printf '\n%d passed, %d failed\n' "${passed}" "${failed}"
  [ "${failed}" -eq 0 ]
}

main "$@"
