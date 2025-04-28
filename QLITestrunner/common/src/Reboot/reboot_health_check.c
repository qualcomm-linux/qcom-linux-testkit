#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <string.h>

#define LOG_DIR "/var/reboot_health"
#define LOG_FILE "/var/reboot_health/reboot_health.log"
#define RESULT_FILE "/var/reboot_health/test_result.txt"  // Separate result file for CI/CD

// Function to check if the system rebooted (log file exists)
int check_system_rebooted() {
    FILE *file = fopen(LOG_FILE, "r");
    if (file == NULL) {
        return 0;  // No log file means no reboot has occurred
    }
    fclose(file);
    return 1;  // Log file exists, system has rebooted
}

// Function to log the result of the health check
void log_health_check(int status) {
    FILE *log_file = fopen(LOG_FILE, "a");
    if (log_file == NULL) {
        perror("Failed to open log file");
        exit(1);
    }

    time_t now = time(NULL);
    char *time_str = ctime(&now);
    time_str[strlen(time_str) - 1] = '\0';  // Remove the newline character from ctime's output

    if (status) {
        fprintf(log_file, "[%s] PASS: System rebooted successfully.\n", time_str);
    } else {
        fprintf(log_file, "[%s] FAIL: System did not reboot successfully.\n", time_str);
    }

    fclose(log_file);
}

// Function to write a result (PASS/FAIL) for CI/CD into a separate file
void write_result_for_cicd(int status) {
    FILE *result_file = fopen(RESULT_FILE, "a");
    if (result_file == NULL) {
        perror("Failed to open result file");
        exit(1);
    }

    time_t now = time(NULL);
    char *time_str = ctime(&now);
    time_str[strlen(time_str) - 1] = '\0';  // Remove the newline character

    if (status) {
        fprintf(result_file, "[%s] PASS\n", time_str);
    } else {
        fprintf(result_file, "[%s] FAIL\n", time_str);
    }

    fclose(result_file);
}

// Function to ensure the log directory exists
void create_log_directory() {
    if (access(LOG_DIR, F_OK) == -1) {
        if (mkdir(LOG_DIR, 0755) != 0) {
            perror("Failed to create log directory");
            exit(1);
        }
    }
}

// Function to check if the log and result files exist, create them if not
void ensure_files_exist() {
    // Create log file if not exists
    FILE *log_file = fopen(LOG_FILE, "a");
    if (log_file == NULL) {
        perror("Failed to open log file");
        exit(1);
    }
    fclose(log_file);  // Close after checking/creating the file

    // Create result file if not exists
    FILE *result_file = fopen(RESULT_FILE, "w");
    if (result_file == NULL) {
        perror("Failed to open result file");
        exit(1);
    }
    fclose(result_file);  // Close after checking/creating the file
}

// Watchdog timer simulation
void watchdog_timer() {
    int counter = 0;
    while (1) {
        sleep(5); // Check every 5 seconds

        counter++;

        if (check_system_rebooted()) {
            log_health_check(1);  // Log success if system rebooted
            write_result_for_cicd(1);  // Write pass to CI/CD result file
            break;  // Exit the loop after success
        }

        if (counter >= 12) {  // Timeout after 1 minute
            log_health_check(0);  // Log failure if no reboot detected
            write_result_for_cicd(0);  // Write fail to CI/CD result file
            break;  // Exit the loop after failure
        }
    }
}

int main() {
    // Ensure the necessary directories and files exist
    create_log_directory();
    ensure_files_exist();

    // Start the watchdog timer
    watchdog_timer();

    return 0;
}
