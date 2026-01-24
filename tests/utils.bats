#!/usr/bin/env bats

setup() {
    # Source the library
    # We use a relative path assuming tests are run from the repo root or tests dir
    # Bats usually runs from the directory where the test file is, or we configure it.
    # The workflow runs `bats tests/` from repo root.
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    source "$DIR/../lib/utils.sh"
}

@test "command_exists returns 0 for existing command" {
  run command_exists ls
  [ "$status" -eq 0 ]
}

@test "command_exists returns 1 for non-existing command" {
  run command_exists non_existing_command_12345
  [ "$status" -eq 1 ]
}

@test "files_differ returns 0 (true) if files differ" {
  echo "content1" > file1
  echo "content2" > file2
  run files_differ file1 file2
  rm file1 file2
  [ "$status" -eq 0 ]
}

@test "files_differ returns 1 (false) if files are same" {
  echo "content" > file1
  echo "content" > file2
  run files_differ file1 file2
  rm file1 file2
  [ "$status" -eq 1 ]
}

@test "files_differ returns 0 (true) if first file is missing" {
  echo "content" > file2
  run files_differ non_existent_file file2
  rm file2
  [ "$status" -eq 0 ]
}

@test "log_info outputs message" {
  run log_info "test info message"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "test info message" ]]
}

@test "log_pass outputs message" {
  CHECKS_PASSED=0
  run log_pass "test pass message"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "test pass message" ]]
}

@test "log_fail outputs message" {
  CHECKS_FAILED=0
  ERRORS=0
  run log_fail "test fail message"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "test fail message" ]]
}
