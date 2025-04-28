#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>
#include <time.h>
#include <sys/reboot.h>

#define HEALTH_DIR "/var/reboot_health"
#define LOG_FILE   "/var/reboot_health/reboot_health.log"
#define SERIAL_PORT "/dev/ttyS0"

// Function to get the current timestamp
void get_timestamp(char *buffer, size_t size) {
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    strftime(buffer, size, "%Y-%m-%d %H:%M:%S", t);
}

// Function to log messages with a specified level
void log_message(const char *level, const char *message) {
    char timestamp[64];
    get_timestamp(timestamp, sizeof(timestamp));

    // Log to file
    FILE *log = fopen(LOG_FILE, "a");
    if (log) {
        fprintf(log, "[%s] [%s] %s\n", timestamp, level, message);
        fclose(log);
    }

    // Log to serial port (for visibility)
    FILE *serial = fopen(SERIAL_PORT, "w");
    if (serial) {
        fprintf(serial, "[%s] [%s] %s\n", timestamp, level, message);
        fclose(serial);
    }
}

// Helper functions for logging
void log_info(const char *message)  { log_message("INFO",  message); }
void log_pass(const char *message)  { log_message("PASS",  message); }
void log_fail(const char *message)  { log_message("FAIL",  message); }
void log_error(const char *message) { log_message("ERROR", message); }

// Check if the system has recently rebooted by reading uptime
void check_system_reboot() {
    FILE *fp;
    char buffer[128];
    unsigned long uptime = 0;

    fp = fopen("/proc/uptime", "r");
    if (fp == NULL) {
        log_error("Failed to read /proc/uptime.");
        exit(1);
    }
    fscanf(fp, "%s", buffer);
    fclose(fp);

    uptime = strtol(buffer, NULL, 10);  // Uptime in seconds

    if (uptime < 300) {  // If uptime is less than 5 minutes, assume the system has rebooted recently
        log_info("System has rebooted recently (uptime < 300 seconds).");
    } else {
        log_info("System uptime is normal (no recent reboot detected).");
    }
}

// Check if the system is running a valid shell (PID 1)
void check_shell_alive() {
    FILE *fp = fopen("/proc/1/comm", "r");
    if (!fp) {
        log_fail("Cannot open /proc/1/comm. System critical error.");
        exit(1);
    }

    char buf[64] = {0};
    if (!fgets(buf, sizeof(buf), fp)) {
        fclose(fp);
        log_fail("Failed to read PID 1 comm.");
        exit(1);
    }
    fclose(fp);

    buf[strcspn(buf, "\n")] = 0; // Remove trailing newline

    if (strstr(buf, "init") || strstr(buf, "systemd") || strstr(buf, "busybox")) {
        char msg[128];
        snprintf(msg, sizeof(msg), "Booted successfully with PID1 -> %s", buf);
        log_pass(msg); // Log PASS
    } else {
        char msg[128];
        snprintf(msg, sizeof(msg), "Boot failed. Unexpected PID1: %s", buf);
        log_fail(msg); // Log FAIL

        log_info("Attempting reboot now...");
        sync();
        reboot(RB_AUTOBOOT);
    }
}

// Create the directory if it doesn't exist
int create_directory_if_not_exists(const char *dir_path) {
    struct stat st = {0};
    if (stat(dir_path, &st) == -1) {
        if (mkdir(dir_path, 0755) == -1) {
            log_error("Failed to create directory /var/reboot_health.");
            return -1;
        }
        log_info("Created directory /var/reboot_health.");
    }
    return 0;
}

int main() {
    // Ensure the directory exists before proceeding
    if (create_directory_if_not_exists(HEALTH_DIR) != 0) {
        log_error("Exiting due to failure in creating directory.");
        return 1;  // Directory creation failed
    }

    check_system_reboot();  // Check if the system has recently rebooted
    check_shell_alive();    // Check if the system shell (PID 1) is alive and healthy

    log_info("Reboot health check completed.");
    return 0;
}
