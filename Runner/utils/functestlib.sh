#	
# Import test suite definitions
source /var/Runner/init_env
#import platform
source $TOOLS/platform.sh

__RUNNER_SUITES_DIR="/var/Runner/suites"
__RUNNER_UTILS_BIN_DIR="/var/common"

#This function used for test logging
log() {
    local level="$1"
	shift
    # echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a /var/test_framework.log
	echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a /var/test_output.log
}
# Find test case path by name
find_test_case_by_name() {
    local test_name="$1"
    find $__RUNNER_SUITES_DIR -type d -iname "$test_name" 2>/dev/null
}

# Find test case path by name
find_test_case_bin_by_name() {
    local test_name="$1"
    find $__RUNNER_UTILS_BIN_DIR -type f -iname "$test_name" 2>/dev/null
}

# Find test case path by name
find_test_case_script_by_name() {
    local test_name="$1"
    find $__RUNNER_UTILS_BIN_DIR -type d -iname "$test_name" 2>/dev/null
}


# Logging levels
log_info() { log "INFO" "$@"; }
log_pass() { log "PASS" "$@"; }
log_fail() { log "FAIL" "$@"; }
log_error() { log "ERROR" "$@"; }


## this doc fn comes last
FUNCTIONS="\
log_info \
log_pass \
log_fail \
log_error \
find_test_case_by_name \
find_test_case_bin_by_name \
find_test_case_script_by_name  \
log \
"

functestlibdoc()
{
  echo "functestlib.sh"
  echo ""
  echo "Functions:"
  for fn in $FUNCTIONS; do
    echo $fn
    eval $fn"_doc"
    echo ""
  done
  echo "Note, these functions will probably not work with >=32 CPUs"
}
