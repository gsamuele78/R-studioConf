#!/usr/bin/env bats

setup() {
    # Load the script to be tested
    # We use logic to find the lib/common_utils.sh relative to this test file
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # Assuming test is in tests/unit/ and lib is in lib/
    LIB_PATH="$DIR/../../lib/common_utils.sh"
    
    # We must source it, but we want to avoid executing any "main" logic if it had any.
    # common_utils.sh is designed to be sourced, so this is safe.
    source "$LIB_PATH"

    # Create a temporary directory for file operations
    TEST_TEMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

# --- Test: check_bash_version ---

@test "check_bash_version: fails for old bash (simulated)" {
    # Mock BASH_VERSINFO array to simulate Bash 3
    BASH_VERSINFO=(3)
    run check_bash_version 4
    [ "$status" -eq 1 ]
}

@test "check_bash_version: passes for current bash (assuming >4)" {
    run check_bash_version 4
    [ "$status" -eq 0 ]
}

# --- Test: process_template ---

@test "process_template: correctly replaces placeholders" {
    # Create a dummy template file
    local template_file="$TEST_TEMP_DIR/template.conf"
    echo "USER=%%USERNAME%%" > "$template_file"
    echo "PATH=%%HOMEDIR%%/bin" >> "$template_file"

    local output_var=""
    
    # Run the function
    process_template "$template_file" output_var "USERNAME=jdoe" "HOMEDIR=/home/jdoe"
    
    # Check status
    [ "$status" -eq 0 ]
    
    # Check content
    local expected_line1="USER=jdoe"
    local expected_line2="PATH=/home/jdoe/bin"
    
    # Use grep to verify lines exist in the output variable
    echo "$output_var" | grep -q "$expected_line1"
    echo "$output_var" | grep -q "$expected_line2"
}

@test "process_template: handles special characters properly" {
    local template_file="$TEST_TEMP_DIR/special.conf"
    echo "URL=%%URL%%" > "$template_file"

    local output_var=""
    # Test with slashes and ampersands which often break sed
    process_template "$template_file" output_var "URL=http://example.com/foo?bar&baz"
    
    echo "$output_var" | grep -Fq "URL=http://example.com/foo?bar&baz"
}

@test "process_template: fails gracefully when file missing" {
    run process_template "$TEST_TEMP_DIR/nonexistent_file" output_var
    [ "$status" -eq 1 ]
}

# --- Test: Dependencies check ---

@test "check_dependencies: fails if command missing" {
    run check_dependencies "non_existent_command_xyz123"
    [ "$status" -eq 1 ]
}

@test "check_dependencies: passes if command exists" {
    run check_dependencies "ls" "grep"
    [ "$status" -eq 0 ]
}
