#!/usr/bin/env bash

# Copyright 2025 Grzegorz Kociolek
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Shell-to-C converter with diagnostics
# Usage: ./s2c input.sh

INPUT="$1"
OUTPUT="output.c"

S2C_EXIT_CODE=0

# Logs a message to stderr with a level.
# Usage: log <level> <message>
log() {
    local level="$1"
    local message="$2"
    echo "$0: ${level}: ${message}" >&2
    if [[ "$level" == "error" ]]; then
        S2C_EXIT_CODE=2
    fi
}

if [[ -z "$INPUT" ]]; then
    log "fatal" "no input file specified"
    echo "Usage: $0 input.sh" >&2
    exit 1
fi

# --- State for helper function usage ---
S2C_HELPER_STR_DUP_USED=0
S2C_HELPER_PIPE_CHAIN_USED=0
S2C_HELPER_FILE_EXISTS_USED=0
S2C_HELPER_IS_REG_USED=0
S2C_HELPER_IS_DIR_USED=0

write_c_header() {
    cat > "$OUTPUT" <<EOF
// -- THIS FILE IS GENERATED BY S2C --

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h> // For SIGTERM
#include <stdbool.h> // For boolean types
#include <sys/stat.h> // For file tests

// --- Global variables ---
int s2c_last_status = 0; // for \$?
int s2c_last_bg_pid = 0; // for \$!

// --- Function Declarations for s2c helpers ---
static char* str_dup(const char* str);
static int s2c_execute_pipe_chain(int num_cmds, char* const cmds[], int* pipestatus_array);
static bool s2c_file_exists(const char* path);
static bool s2c_is_reg(const char* path);
static bool s2c_is_dir(const char* path);

// main function begins
int main() {
EOF
}

get_str_dup_impl() {
    cat <<'EOF'

// Portable string duplication
static char* str_dup(const char* str) {
    if (!str) return NULL;
    size_t len = strlen(str);
    char* result = malloc(len + 1);
    if (!result) return NULL;
    memcpy(result, str, len + 1);
    return result;
}
EOF
}

get_s2c_execute_pipe_chain_impl() {
    cat <<'EOF'

// Function to execute a chain of commands connected by pipes
// Returns the exit status of the last command in the pipeline.
// Fills pipestatus_array with the exit status of each command.
static int s2c_execute_pipe_chain(int num_cmds, char* const cmds[], int* pipestatus_array) {
    if (num_cmds <= 0) {
        return -1; // Error or undefined behavior
    }

    pid_t* pids = malloc(num_cmds * sizeof(pid_t));
    if (!pids) { perror("malloc: pids"); return -1; }

    int* status = malloc(num_cmds * sizeof(int));
    if (!status) { perror("malloc: status"); free(pids); return -1; }

    int last_status = -1;

    // Handle a single command (no pipes needed)
    if (num_cmds == 1) {
        if (cmds[0] == NULL) { free(pids); free(status); return -1; }
        pids[0] = fork();
        if (pids[0] < 0) {
            perror("fork (single command)");
            free(pids); free(status);
            return -1; // Fork failed
        }
        if (pids[0] == 0) { // Child process
            execlp("/bin/sh", "sh", "-c", cmds[0], (char *)NULL);
            perror("execlp (single command)"); // execlp only returns on error
            exit(127); // Exit if execlp fails
        }
        // Parent process
        int wstatus_single;
        waitpid(pids[0], &wstatus_single, 0);
        if (WIFEXITED(wstatus_single)) {
            status[0] = WEXITSTATUS(wstatus_single);
        } else {
            status[0] = 127; // Mimic shell behavior for non-exit signals/errors
        }
        if (pipestatus_array) {
            pipestatus_array[0] = status[0];
        }
        last_status = status[0];
        free(pids);
        free(status);
        return last_status;
    }

    // More than one command, pipes are needed (num_cmds > 1)
    int (*pipefd)[2] = malloc((num_cmds - 1) * sizeof(int[2]));
    if (!pipefd) {
        perror("malloc: pipefd");
        free(pids); free(status);
        return -1;
    }

    // Create all necessary pipes
    for (int i = 0; i < num_cmds - 1; ++i) {
        if (pipe(pipefd[i]) < 0) {
            perror("pipe");
            for (int k = 0; k < i; ++k) {
                close(pipefd[k][0]);
                close(pipefd[k][1]);
            }
            free(pipefd); free(pids); free(status);
            return -1; // Pipe creation failed
        }
    }

    // Fork children and execute commands
    for (int i = 0; i < num_cmds; ++i) {
        pids[i] = -1; // Initialize pid entry
        if (cmds[i] == NULL) {
            // This is a critical error, try to clean up and signal failure.
            for (int k = 0; k < num_cmds - 1; ++k) {
                close(pipefd[k][0]);
                close(pipefd[k][1]);
            }
             // Attempt to kill and reap already forked children
            for (int k = 0; k < i; ++k) {
                if (pids[k] > 0) { // Check if pid is valid
                   kill(pids[k], SIGTERM);
                   waitpid(pids[k], NULL, 0);
                }
            }
            free(pipefd); free(pids); free(status);
            return -1; // Indicate error
        }
        pids[i] = fork();
        if (pids[i] < 0) {
            perror("fork");
            // Fork failed: clean up pipes and attempt to reap/kill already forked children
            for (int k = 0; k < num_cmds - 1; ++k) { // Close parent's pipe ends
                close(pipefd[k][0]);
                close(pipefd[k][1]);
            }
            for (int k = 0; k < i; ++k) { // Kill and reap children that were successfully forked
                if (pids[k] > 0) {
                    kill(pids[k], SIGTERM);
                    waitpid(pids[k], NULL, 0);
                }
            }
            free(pipefd); free(pids); free(status);
            return -1; // Fork failed
        }

        if (pids[i] == 0) { // Child process
            // Redirect input from the previous command's pipe
            if (i > 0) { // If not the first command
                if (dup2(pipefd[i-1][0], STDIN_FILENO) < 0) {
                    perror("dup2 stdin");
                    exit(127);
                }
            }
            // Redirect output to the next command's pipe
            if (i < num_cmds - 1) { // If not the last command
                if (dup2(pipefd[i][1], STDOUT_FILENO) < 0) {
                    perror("dup2 stdout");
                    exit(127);
                }
            }

            // Close all pipe file descriptors in the child (they've been duped or are not needed)
            for (int j = 0; j < num_cmds - 1; ++j) {
                close(pipefd[j][0]);
                close(pipefd[j][1]);
            }

            // Execute the command
            execlp("/bin/sh", "sh", "-c", cmds[i], (char *)NULL);
            perror("execlp"); // execlp only returns on error
            exit(127);    // Exit if execlp fails
        }
    }

    // Parent process: close all its pipe file descriptors
    for (int i = 0; i < num_cmds - 1; ++i) {
        close(pipefd[i][0]);
        close(pipefd[i][1]);
    }

    // Wait for all child processes and collect their exit statuses
    for (int i = 0; i < num_cmds; ++i) {
        int wstatus;
        waitpid(pids[i], &wstatus, 0);
        if (WIFEXITED(wstatus)) {
            status[i] = WEXITSTATUS(wstatus);
        } else {
            status[i] = 127; // Mimic shell behavior for non-exit signals/errors
        }
        if (pipestatus_array) { // Ensure pipestatus_array is not NULL before dereferencing
            pipestatus_array[i] = status[i];
        }
    }
    
    last_status = status[num_cmds - 1]; // num_cmds is > 0 here
    
    free(pipefd);
    free(pids);
    free(status);
    return last_status;
}
EOF
}

get_s2c_file_exists_impl() {
    cat <<'EOF'

// Helper for test -e
static bool s2c_file_exists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0;
}
EOF
}

get_s2c_is_reg_impl() {
    cat <<'EOF'

// Helper for test -f
static bool s2c_is_reg(const char* path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}
EOF
}

get_s2c_is_dir_impl() {
    cat <<'EOF'

// Helper for test -d
static bool s2c_is_dir(const char* path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}
EOF
}

write_c_footer() {
    echo "    return 0;" >> "$OUTPUT"
    echo "}" >> "$OUTPUT"

    if [[ $S2C_HELPER_STR_DUP_USED -eq 1 ]]; then
        get_str_dup_impl >> "$OUTPUT"
    fi
    if [[ $S2C_HELPER_PIPE_CHAIN_USED -eq 1 ]]; then
        get_s2c_execute_pipe_chain_impl >> "$OUTPUT"
    fi
    if [[ $S2C_HELPER_FILE_EXISTS_USED -eq 1 ]]; then
        get_s2c_file_exists_impl >> "$OUTPUT"
    fi
    if [[ $S2C_HELPER_IS_REG_USED -eq 1 ]]; then
        get_s2c_is_reg_impl >> "$OUTPUT"
    fi
    if [[ $S2C_HELPER_IS_DIR_USED -eq 1 ]]; then
        get_s2c_is_dir_impl >> "$OUTPUT"
    fi
}

write_diag() {
    log "error" "untranslated command: '$1'"
    echo "$indent// UNTRANSLATED: $1" >> "$OUTPUT"
}

process_variables() {
    local text="$1"
    local original_text="$1" # Keep original text for no-args case
    local printf_fmt="$text"
    local printf_args=""
    local prefix
    local var_name
    local suffix

    # Handle variable substitutions, including special ones like $? and $!
    while [[ "$printf_fmt" =~ (.*)(\$[a-zA-Z_][a-zA-Z0-9_]*|\$\{[a-zA-Z_][a-zA-Z0-9_]*\}|\$\?|\$!)(.*)$ ]]; do
        prefix="${BASH_REMATCH[1]}"
        local var_expression="${BASH_REMATCH[2]}"
        suffix="${BASH_REMATCH[3]}"
        local c_var_name=""
        local format_specifier="%s"

        if [[ "$var_expression" == '$?' ]]; then
            c_var_name="s2c_last_status"
            format_specifier="%d"
        elif [[ "$var_expression" == '$!' ]]; then
            c_var_name="s2c_last_bg_pid"
            format_specifier="%d"
        else
            # Extract var_name from $VAR or ${VAR}
            c_var_name=${var_expression#\$}
            c_var_name=${c_var_name#\{}
            c_var_name=${c_var_name%\}}
        fi

        if [[ -z "$printf_args" ]]; then
            printf_args="$c_var_name"
        else
            # Prepend to keep original order for printf
            printf_args="$c_var_name, $printf_args"
        fi
        printf_fmt="${prefix}${format_specifier}${suffix}"
    done

    if [[ -n "$printf_args" ]]; then
        local final_fmt_to_echo="$printf_fmt"
        # Corrected quote stripping: use \" in code_edit to get " in script.
        if [[ "$printf_fmt" == \"*\" && "${printf_fmt: -1}" == \" && ${#printf_fmt} -ge 2 ]]; then # Check start and end quote
            local inner_content="${printf_fmt#\"}" # Remove leading "
            inner_content="${inner_content%\"}"   # Remove trailing "
            final_fmt_to_echo="$inner_content"
        fi
        echo "$final_fmt_to_echo"
        echo "$printf_args"
    else
        local final_text_to_echo="$original_text"
        # Corrected quote stripping: use \" in code_edit to get " in script.
        if [[ "$original_text" == \"*\" && "${original_text: -1}" == \" && ${#original_text} -ge 2 ]]; then # Check start and end quote
            local inner_content="${original_text#\"}"
            inner_content="${inner_content%\"}"
            final_text_to_echo="$inner_content"
        fi
        echo "$final_text_to_echo"
        echo ""
    fi
}

translate_echo() {
    local text="$1"
    local output
    local result_fmt
    local result_args

    output=$(process_variables "$text")
    result_fmt=$(echo "$output" | sed -n '1p')
    result_args=$(echo "$output" | sed -n '2p')

    if [[ -n "$result_args" ]]; then
        printf '%s\n' "$indent if (printf(\"$result_fmt\\n\", $result_args) < 0) {" >> "$OUTPUT"
        printf '%s\n' "$indent     s2c_last_status = 1;" >> "$OUTPUT"
        printf '%s\n' "$indent } else {" >> "$OUTPUT"
        printf '%s\n' "$indent     s2c_last_status = 0;" >> "$OUTPUT"
        printf '%s\n' "$indent }" >> "$OUTPUT"
    else
        # If no args, result_fmt is the original text
        printf '%s\n' "$indent if (printf(\"%s\\n\", \"$result_fmt\") < 0) {" >> "$OUTPUT"
        printf '%s\n' "$indent     s2c_last_status = 1;" >> "$OUTPUT"
        printf '%s\n' "$indent } else {" >> "$OUTPUT"
        printf '%s\n' "$indent     s2c_last_status = 0;" >> "$OUTPUT"
        printf '%s\n' "$indent }" >> "$OUTPUT"
    fi
}

translate_system() {
    local cmd="$1"
    echo "$indent s2c_last_status = system(\"$cmd\");" >> "$OUTPUT"
}

translate_cd() {
    local dir="$1"
    echo "$indent chdir(\"$dir\");" >> "$OUTPUT"
}

translate_if() {
    local cond="$1"
    # The cond might be `[ ... ]` or `test ...`
    local inner_cond
    if [[ "$cond" =~ ^\[(.*)\]$ ]]; then
        inner_cond="${BASH_REMATCH[1]}"
    elif [[ "$cond" =~ ^test[[:space:]]+(.+) ]]; then
        inner_cond="${BASH_REMATCH[1]}"
    else
        inner_cond="$cond"
    fi
    
    # Trim whitespace from the condition before parsing
    inner_cond=$(echo "$inner_cond" | xargs)

    local c_cond
    translate_shell_test_to_c_condition "$inner_cond"
    c_cond="$S2C_C_CONDITION_RESULT"
    echo "$indent if ($c_cond) {" >> "$OUTPUT"
    indent="    $indent"
}

translate_else() {
    indent="${indent:4}"
    echo "$indent } else {" >> "$OUTPUT"
    indent="    $indent"
}

translate_fi() {
    indent="${indent:4}"
    echo "$indent }" >> "$OUTPUT"
}

translate_for() {
    local var="$1"
    local list="$2"
    local quoted_list=""
    local in_quotes=0
    local current_word=""
    local words=()
    local char
    local word
    local i
    
    # Parse the list preserving quotes
    for (( i=0; i<${#list}; i++ )); do
        char="${list:$i:1}"
        if [[ "$char" == '"' ]]; then
            in_quotes=$((1-in_quotes))
            current_word+="$char"
        elif [[ "$char" == ' ' && $in_quotes -eq 0 ]]; then
            if [[ -n "$current_word" ]]; then
                words+=("$current_word")
                current_word=""
            fi
        else
            current_word+="$char"
        fi
    done
    if [[ -n "$current_word" ]]; then
        words+=("$current_word")
    fi
    
    # Build the quoted list in correct order
    for word in "${words[@]}"; do
        if [[ -n "$quoted_list" ]]; then
            quoted_list="$quoted_list, "
        fi
        # If word is already quoted, use it as is, otherwise add quotes
        if [[ "$word" =~ ^\".*\"$ ]]; then
            quoted_list="$quoted_list$word"
        else
            quoted_list="$quoted_list\"$word\""
        fi
    done
    
    echo "$indent char* arr[] = { $quoted_list };" >> "$OUTPUT"
    echo "$indent for (int i = 0; i < sizeof(arr)/sizeof(arr[0]); ++i) {" >> "$OUTPUT"
    echo "$indent     char* $var = arr[i];" >> "$OUTPUT"
    indent="    $indent"
}

translate_done() {
    indent="${indent:4}"
    echo "$indent }" >> "$OUTPUT"
}

translate_command_subst() {
    local var="$1"
    local cmd="$2"
    local current_indent_str="$3" # New argument for indentation

    # First, handle variable substitutions in the command
    local output
    local result_fmt
    local result_args
    output=$(process_variables "$cmd")
    result_fmt=$(echo "$output" | sed -n '1p')
    result_args=$(echo "$output" | sed -n '2p')

    local cmd_var="cmd_for_${var}"
    echo "$current_indent_str char $cmd_var[1024];" >> "$OUTPUT"

    if [[ -n "$result_args" ]]; then
        # Command has variables, they need to be interpolated at runtime in C
        # The format string from process_variables needs to be escaped for C
        local c_fmt
        c_fmt=$(echo "$result_fmt" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "$current_indent_str snprintf($cmd_var, sizeof($cmd_var), \"$c_fmt\", $result_args);" >> "$OUTPUT"
    else
        # Command is a literal string, just need to escape it for C
        local c_cmd
        c_cmd=$(echo "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "$current_indent_str snprintf($cmd_var, sizeof($cmd_var), \"%s\", \"$c_cmd\");" >> "$OUTPUT"
    fi

    echo "$current_indent_str char $var[256];" >> "$OUTPUT"
    echo "$current_indent_str FILE* fp_$var = popen($cmd_var, \"r\");" >> "$OUTPUT"
    echo "$current_indent_str if (fp_$var) {" >> "$OUTPUT"
    echo "$current_indent_str     if (fgets($var, sizeof($var), fp_$var)) {" >> "$OUTPUT"
    echo "$current_indent_str         char* newline = strchr($var, '\\n');" >> "$OUTPUT"
    echo "$current_indent_str         if (newline) *newline = '\\0';" >> "$OUTPUT"
    echo "$current_indent_str     } else {" >> "$OUTPUT"
    echo "$current_indent_str         $var[0] = '\\0';" >> "$OUTPUT"
    echo "$current_indent_str     }" >> "$OUTPUT"
    echo "$current_indent_str     s2c_last_status = pclose(fp_$var);" >> "$OUTPUT"
    echo "$current_indent_str } else {" >> "$OUTPUT" # Handle popen failure
    echo "$current_indent_str     $var[0] = '\\0';" >> "$OUTPUT" # Initialize var if popen failed
    echo "$current_indent_str }" >> "$OUTPUT"
}

translate_pipe_chain() {
    local line="$1"
    S2C_HELPER_PIPE_CHAIN_USED=1
    IFS='|' read -ra cmds <<< "$line"
    local ncmds=${#cmds[@]}

    echo "$indent {" >> "$OUTPUT"
    echo "$indent     int n_pipe_cmds = $ncmds;" >> "$OUTPUT"
    echo "$indent     char* c_cmds[n_pipe_cmds];" >> "$OUTPUT"
    echo "$indent     char cmd_buffers[n_pipe_cmds][1024];" >> "$OUTPUT"

    for i in "${!cmds[@]}"; do
        local cmd_trimmed
        cmd_trimmed=$(echo "${cmds[$i]}" | xargs)

        local output
        local result_fmt
        local result_args
        output=$(process_variables "$cmd_trimmed")
        result_fmt=$(echo "$output" | sed -n '1p')
        result_args=$(echo "$output" | sed -n '2p')

        if [[ -n "$result_args" ]]; then
            local c_fmt
            c_fmt=$(echo "$result_fmt" | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "$indent     snprintf(cmd_buffers[$i], sizeof(cmd_buffers[$i]), \"$c_fmt\", $result_args);" >> "$OUTPUT"
            echo "$indent     c_cmds[$i] = cmd_buffers[$i];" >> "$OUTPUT"
        else
            local cmd_escaped
            cmd_escaped=$(echo "$result_fmt" | sed 's/\\/\\\\/g; s/"/\\"/g')
            echo "$indent     c_cmds[$i] = \"$cmd_escaped\";" >> "$OUTPUT"
        fi
    done

    echo "$indent     int _PIPESTATUS[n_pipe_cmds];" >> "$OUTPUT"
    echo "$indent     for (int k = 0; k < n_pipe_cmds; ++k) { _PIPESTATUS[k] = -1; }" >> "$OUTPUT"
    echo "$indent     s2c_last_status = s2c_execute_pipe_chain(n_pipe_cmds, c_cmds, _PIPESTATUS);" >> "$OUTPUT"
    echo "$indent }" >> "$OUTPUT"
}

translate_background() {
    local cmd="$1"
    local output
    local result_fmt
    local result_args
    output=$(process_variables "$cmd")
    result_fmt=$(echo "$output" | sed -n '1p')
    result_args=$(echo "$output" | sed -n '2p')

    echo "$indent {" >> "$OUTPUT"
    echo "$indent     pid_t bg_pid;" >> "$OUTPUT"
    echo "$indent     char cmd_buffer[1024];" >> "$OUTPUT"

    if [[ -n "$result_args" ]]; then
        local c_fmt
        c_fmt=$(echo "$result_fmt" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "$indent     snprintf(cmd_buffer, sizeof(cmd_buffer), \"$c_fmt\", $result_args);" >> "$OUTPUT"
    else
        local cmd_escaped
        cmd_escaped=$(echo "$result_fmt" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "$indent     snprintf(cmd_buffer, sizeof(cmd_buffer), \"%s\", \"$cmd_escaped\");" >> "$OUTPUT"
    fi

    echo "$indent     if ((bg_pid = fork()) == 0) {" >> "$OUTPUT"
    echo "$indent         if (fork() == 0) {" >> "$OUTPUT"
    echo "$indent             setsid();" >> "$OUTPUT"
    echo "$indent             execlp(\"/bin/sh\", \"sh\", \"-c\", cmd_buffer, NULL);" >> "$OUTPUT"
    echo "$indent             exit(127);" >> "$OUTPUT"
    echo "$indent         }" >> "$OUTPUT"
    echo "$indent         exit(0);" >> "$OUTPUT"
    echo "$indent     }" >> "$OUTPUT"
    echo "$indent     if (bg_pid > 0) {" >> "$OUTPUT"
    echo "$indent         int wstatus;" >> "$OUTPUT"
    echo "$indent         waitpid(bg_pid, &wstatus, 0);" >> "$OUTPUT"
    echo "$indent         s2c_last_bg_pid = bg_pid;" >> "$OUTPUT"
    echo "$indent     }" >> "$OUTPUT"
    echo "$indent }" >> "$OUTPUT"
}

translate_var_assign() {
    local var="$1"
    local val="$2"
    # Fix: assign variable as a C string, but if value is a variable, assign as pointer
    if [[ "$val" =~ ^\$([a-zA-Z_][a-zA-Z0-9_]*)$ ]]; then
        echo "$indent char* $var = ${BASH_REMATCH[1]};" >> "$OUTPUT"
    elif [[ "$val" =~ ^\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}$ ]]; then
        echo "$indent char* $var = ${BASH_REMATCH[1]};" >> "$OUTPUT"
    else
        echo "$indent char* $var = \"$val\";" >> "$OUTPUT"
    fi
}

translate_var_usage() {
    local line="$1"
    local output
    local result_fmt
    local result_args

    output=$(process_variables "$line")
    result_fmt=$(echo "$output" | sed -n '1p')
    result_args=$(echo "$output" | sed -n '2p')

    if [[ -n "$result_args" ]]; then
        printf '%s\n' "$indent printf(\"$result_fmt\\n\", $result_args);" >> "$OUTPUT"
    else
        printf '%s\n' "$indent printf(\"%s\\n\", \"$result_fmt\");" >> "$OUTPUT"
    fi
}

translate_string_with_vars() {
    local str="$1"
    local output
    local result_fmt
    local result_args
    local temp_var

    output=$(process_variables "$str")
    result_fmt=$(echo "$output" | sed -n '1p')
    result_args=$(echo "$output" | sed -n '2p')

    if [[ -n "$result_args" ]]; then
        temp_var="temp_${RANDOM}"
        echo "$indent char ${temp_var}[1024];" >> "$OUTPUT"
        echo "$indent snprintf(${temp_var}, sizeof(${temp_var}), \"$result_fmt\", $result_args);" >> "$OUTPUT"
        echo "$temp_var"  # Return the temp variable name
    else
        echo "\"$result_fmt\""  # Return the literal string (already quoted by process_variables if no vars)
    fi
}

# Splits a line into words, respecting double quotes.
# Usage: parse_line_into_words "line to parse" "my_array"
parse_line_into_words() {
    local line="$1"
    local -n out_array=$2 # nameref to output array

    out_array=()
    local current_word=""
    local in_quotes=0
    local i
    local char
    for (( i=0; i<${#line}; i++ )); do
        char="${line:$i:1}"
        if [[ "$char" == '"' ]]; then
            in_quotes=$((1-in_quotes))
            # Not adding quote to the word itself
        elif [[ "$char" == ' ' && $in_quotes -eq 0 ]]; then
            if [[ -n "$current_word" ]]; then
                out_array+=("$current_word")
                current_word=""
            fi
        else
            current_word+="$char"
        fi
    done
    if [[ -n "$current_word" ]]; then
        out_array+=("$current_word")
    fi
}

# Converts a shell token to its C representation (var name or string literal)
arg_to_c() {
    local arg=$1
    if [[ "$arg" =~ ^\$([a-zA-Z_][a-zA-Z0-9_]*)$ ]]; then
        echo -n "${BASH_REMATCH[1]}"
    elif [[ "$arg" =~ ^\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}$ ]]; then
        echo -n "${BASH_REMATCH[1]}"
    else
        # It's a literal. Needs to be a C string literal.
        local escaped_arg="${arg//\\/\\\\}"
        escaped_arg="${escaped_arg//\"/\\\"}"
        echo -n "\"$escaped_arg\""
    fi
}

# Translates a shell test expression into a C conditional expression.
# The result is stored in the global variable S2C_C_CONDITION_RESULT.
translate_shell_test_to_c_condition() {
    local cond="$1"
    local words
    parse_line_into_words "$cond" words
    local c_cond=""

    if [[ ${#words[@]} -eq 1 ]]; then
        c_cond="strlen($(arg_to_c "${words[0]}")) > 0"
    elif [[ ${#words[@]} -eq 2 ]]; then
        local op="${words[0]}"
        local c_arg1="$(arg_to_c "${words[1]}")"
        case "$op" in
            -n) c_cond="strlen($c_arg1) > 0" ;;
            -z) c_cond="strlen($c_arg1) == 0" ;;
            -f) S2C_HELPER_IS_REG_USED=1; c_cond="s2c_is_reg($c_arg1)" ;;
            -d) S2C_HELPER_IS_DIR_USED=1; c_cond="s2c_is_dir($c_arg1)" ;;
            -e) S2C_HELPER_FILE_EXISTS_USED=1; c_cond="s2c_file_exists($c_arg1)" ;;
            *)
                log "error" "unsupported test operator: '$op' in expression: '$cond'"
                c_cond="0 /* unsupported test op: $op */"
                ;;
        esac
    elif [[ ${#words[@]} -eq 3 ]]; then
        local c_arg1="$(arg_to_c "${words[0]}")"
        local op="${words[1]}"
        local c_arg2="$(arg_to_c "${words[2]}")"
        case "$op" in
            '='|'==') c_cond="strcmp($c_arg1, $c_arg2) == 0" ;;
            '!=') c_cond="strcmp($c_arg1, $c_arg2) != 0" ;;
            -eq) c_cond="atoi($c_arg1) == atoi($c_arg2)" ;;
            -ne) c_cond="atoi($c_arg1) != atoi($c_arg2)" ;;
            -gt) c_cond="atoi($c_arg1) > atoi($c_arg2)" ;;
            -lt) c_cond="atoi($c_arg1) < atoi($c_arg2)" ;;
            -ge) c_cond="atoi($c_arg1) >= atoi($c_arg2)" ;;
            -le) c_cond="atoi($c_arg1) <= atoi($c_arg2)" ;;
            *)
                log "error" "unsupported test operator: '$op' in expression: '$cond'"
                c_cond="0 /* unsupported test op: $op */"
                ;;
        esac
    else
        log "error" "unsupported test expression: '$cond'"
        c_cond="0 /* unsupported test expression */"
    fi
    S2C_C_CONDITION_RESULT="$c_cond"
}

# Translates a shell arithmetic expression into a C arithmetic expression.
translate_arith_expression() {
    local expr="$1"
    local c_expr=""
    # Add spaces around operators and variables to allow simple splitting.
    expr=$(echo "$expr" | sed -E 's/(\$[a-zA-Z_][a-zA-Z0-9_]*|\$\{[^}]+\}|[a-zA-Z_][a-zA-Z0-9_]*)/ \1 /g' | sed -E 's/(\+|\-|\*|\/|\%|\(|\))/ \1 /g')
    local parts=($expr)
    local part
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^\$([a-zA-Z_][a-zA-Z0-9_]*)$ ]]; then
            c_expr+="atoi(${BASH_REMATCH[1]})"
        elif [[ "$part" =~ ^\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}$ ]]; then
            c_expr+="atoi(${BASH_REMATCH[1]})"
        elif [[ "$part" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            # It's a bare variable name, which is common in arithmetic expansion
            c_expr+="atoi($part)"
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            c_expr+="$part"
        else # operator or parenthesis
            c_expr+=" $part "
        fi
    done
    echo "$c_expr"
}

translate_test() {
    local expr="$1"
    local c_cond
    translate_shell_test_to_c_condition "$expr"
    c_cond="$S2C_C_CONDITION_RESULT"
    echo "$indent s2c_last_status = !($c_cond);" >> "$OUTPUT"
}

# --- Main translation logic ---
process_command() {
    local cmd="$1"
    local trimmed_cmd
    trimmed_cmd="$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Fix: If a command from a one-liner ends in a separator ';', remove it.
    if [[ "${trimmed_cmd: -1}" == ";" ]]; then
        trimmed_cmd="${trimmed_cmd%;}"
    fi

    if [[ -z "$trimmed_cmd" ]] || [[ "$trimmed_cmd" =~ ^# ]]; then
        return
    fi

    # Fallback to simple command processing
    if [[ "$trimmed_cmd" =~ \| ]]; then
        translate_pipe_chain "$trimmed_cmd"
    elif [[ "$trimmed_cmd" =~ ^echo[[:space:]]+(.+) ]]; then
        translate_echo "${BASH_REMATCH[1]}"
    elif [[ "$trimmed_cmd" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=\$\(\((.+)\)\) ]]; then
        local var="${BASH_REMATCH[1]}"
        local expr="${BASH_REMATCH[2]}"
        local c_expr
        c_expr=$(translate_arith_expression "$expr")
        echo "$indent char $var[256];" >> "$OUTPUT"
        echo "$indent snprintf($var, sizeof($var), \"%d\", $c_expr);" >> "$OUTPUT"
    elif [[ "$trimmed_cmd" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=\$\((.*)\)$ ]]; then
        translate_command_subst "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$indent"
    elif [[ "$trimmed_cmd" =~ ^expr[[:space:]]+(.+) ]]; then
        local expr="${BASH_REMATCH[1]//\\\*/*}"
        local c_expr
        c_expr=$(translate_arith_expression "$expr")
        echo "$indent printf(\"%d\\n\", $c_expr);" >> "$OUTPUT"
    elif [[ "$trimmed_cmd" =~ ^\[(.*)\]$ ]]; then
        translate_test "${BASH_REMATCH[1]}"
    elif [[ "$trimmed_cmd" =~ ^test[[:space:]]+(.+) ]]; then
        translate_test "${BASH_REMATCH[1]}"
    elif [[ "$trimmed_cmd" =~ ^cd[[:space:]]+(.+) ]]; then
        translate_cd "${BASH_REMATCH[1]}"
    elif [[ "$trimmed_cmd" =~ ^if[[:space:]]+(.+) ]]; then
        translate_if "${BASH_REMATCH[1]}"
    elif [[ "$trimmed_cmd" == "then" ]]; then
        return # keyword ignored
    elif [[ "$trimmed_cmd" == "else" ]]; then
        translate_else
    elif [[ "$trimmed_cmd" == "fi" ]]; then
        translate_fi
    elif [[ "$trimmed_cmd" =~ ^for[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]+in[[:space:]]+(.+) ]]; then
        local forvar="${BASH_REMATCH[1]}"
        local forlist
        forlist=$(echo "${BASH_REMATCH[2]}" | sed -e 's/[[:space:]]*do$//')
        translate_for "$forvar" "$forlist"
    elif [[ "$trimmed_cmd" == "do" ]]; then
        return # keyword ignored
    elif [[ "$trimmed_cmd" == "done" ]]; then
        translate_done
    elif [[ "$trimmed_cmd" =~ (.+)[[:space:]]+\&$ ]]; then
        translate_background "${BASH_REMATCH[1]}"
    elif [[ "$trimmed_cmd" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=\"(.*)\"$ ]]; then
        translate_var_assign "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$trimmed_cmd" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=([^[:space:]]+)$ ]]; then
        translate_var_assign "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$trimmed_cmd" =~ ^(ls|pwd|whoami|date)(.*) ]]; then
        translate_echo "${BASH_REMATCH[1]}"
    elif [[ "$trimmed_cmd" =~ \$([a-zA-Z_][a-zA-Z0-9_]*)|\$\{[a-zA-Z_][a-zA-Z0-9_]*\} ]]; then
        translate_var_usage "$trimmed_cmd"
    else
        write_diag "$trimmed_cmd"
    fi
}

main() {
    indent="    "
    write_c_header

    # Pre-process the script to handle complex one-liners by separating
    # commands and keywords onto their own lines for reliable parsing.
    local processed_content
    processed_content=$(<"$INPUT" sed -E 's/[[:space:]]*;[[:space:]]*/\n/g' | \
        sed -E 's/[[:space:]]*(then|else|fi|do|done)[[:space:]]*/\n\1\n/g' | \
        sed '/^[[:space:]]*$/d')

    while IFS= read -r cmd; do
        process_command "$cmd"
    done <<< "$processed_content"

    write_c_footer
}

main

exit $S2C_EXIT_CODE

