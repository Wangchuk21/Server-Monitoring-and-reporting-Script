#!/bin/bash
#
# =============================================================================
# Server Monitoring & Diagnostics Script
#
# Use Case:
#   - Monitor your server's load, active connections, and web traffic.
#   - Automatically detect load spikes and send detailed email alerts.
#   - Support multiple PHP-FPM versions (e.g., php7.4-fpm, php8.1-fpm, etc.) 
#     without manual adjustments.
#   - Generate and email a daily server report including system overview,
#     web traffic, process details, and security log excerpts.
#
# Requirements:
#   - Linux OS (Ubuntu, CentOS, Debian, etc.)
#   - Bash shell (version 4 or higher recommended)
#   - systemd for service management (systemctl)
#   - Utilities: netstat, ps, grep, awk, sort, curl, mail
#   - Web Server: Nginx or Apache (with proper logging enabled)
#   - PHP-FPM services for different PHP versions
#   - MySQL for database diagnostics (optional)
#
# Installation:
#   1. Save this script as "server_monitor.sh".
#   2. Make it executable:
#         chmod +x server_monitor.sh
#   3. Ensure required utilities are installed and mail is configured.
#
# Configuration (edit as needed):
#   - EMAIL: Recipient email address for alerts and daily reports.
#   - LOAD_THRESHOLD: Load value that triggers an alert.
#   - CHECK_INTERVAL: Seconds between each check.
#   - ALERT_COOLDOWN: Seconds to wait between consecutive alerts.
#   - WEB_SERVER_LOG: Path to the web server error log.
#   - LOG_FILE: Local file to log alert events.
#   - REPORT_TIME: Time (HH:MM in 24-hour format) to send the daily report.
#
# Usage:
#   Run the script in the background:
#         nohup ./server_monitor.sh &
#
# =============================================================================

# Configuration
EMAIL="your@email.com"
LOAD_THRESHOLD=15
CHECK_INTERVAL=5
ALERT_COOLDOWN=300
WEB_SERVER_LOG="/var/log/nginx/error.log"  # For Apache, use "/var/log/apache2/error.log"
LOG_FILE="/var/log/server_monitor.log"
REPORT_TIME="16:00"  # Daily report time (e.g., 16:00 for 4 PM)

# Global variable to track the last alert time
LAST_ALERT=0

# -----------------------------------------------------------------------------
# Function: get_web_diagnostics
#
# Purpose:
#   Gather diagnostic information on your web server, including active
#   connections, top URLs accessed, server status, PHP-FPM status (for all
#   active PHP versions), database connections, and recent errors.
#
# -----------------------------------------------------------------------------
get_web_diagnostics() {
    # Detect the web server type (nginx or apache2)
    if systemctl is-active --quiet nginx; then
        web_server="nginx"
    elif systemctl is-active --quiet apache2; then
        web_server="apache2"
    else
        web_server="unknown"
    fi

    diagnostics=$(cat <<EOF

=== WEB SERVER DIAGNOSTICS ===

--- Active Connections ---
\$(netstat -nt | grep ':80\\|:443' | awk '{print \$5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -n10)

--- Top URLs (Last 5 Min) ---
\$(tail -5000 /var/log/\${web_server}/access.log | awk '{print \$7}' | sort | uniq -c | sort -nr | head -n10)

--- Server Status ---
\$(
if [ "\$web_server" = "nginx" ]; then
    echo "Nginx Active Connections: \$(curl -s http://127.0.0.1/nginx_status | grep active)"
elif [ "\$web_server" = "apache2" ]; then
    echo "Apache Workers:"
    apachectl fullstatus | grep -E 'CPU|Idle|Req' | head -n5
fi
)

=== PHP-FPM STATUS (All Versions) ===
\$(
# Detect all active PHP-FPM versions using a regex to match service names
php_versions=\$(systemctl list-units --type=service --state=running | grep -oP 'php(\\d+\\.?\\d*)-fpm' | sort -u)
if [ -n "\$php_versions" ]; then
    for version in \$php_versions; do
        echo "--- PHP \${version} ---"
        # Process count for each PHP-FPM service
        echo "Active processes: \$(ps -ef | grep "\${version}" | grep -v grep | wc -l)"
        # Display top memory users for the PHP-FPM service
        echo "Top memory users:"
        ps -eo pid,user,%mem,command ax | grep "\${version}" | grep -v grep | sort -nr -k3 | head -n3
        # Locate the pool configuration file (e.g., www.conf) and show key settings
        pool_conf=\$(find /etc/php/\${version#php} -name "www.conf" 2>/dev/null | head -1)
        if [ -f "\$pool_conf" ]; then
            echo -e "\nPool Settings:"
            grep -E 'pm.max_children|pm.start_servers|pm.max_spare_servers' "\$pool_conf"
        fi
        echo -e "\n"
    done
else
    echo "No active PHP-FPM versions found"
fi
)

--- Database & Other Diagnostics ---
\$(
if systemctl is-active --quiet mysql; then
    echo "MySQL Connections: \$(mysql -NBe "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | awk '{print \$2}')"
    echo "Slow Queries:"
    mysql -NBe "SELECT LEFT(query,100), ROUND(time,2) FROM mysql.slow_log ORDER BY start_time DESC LIMIT 3;" 2>/dev/null
fi
)
\$(
echo "--- Recent Errors ---"
grep -i -E 'error|timeout|failed' \$WEB_SERVER_LOG | tail -n5
)
EOF
)
    echo "\$diagnostics"
}

# -----------------------------------------------------------------------------
# Function: send_alert
#
# Purpose:
#   Sends an email alert with a given subject and body.
#   Logs the alert event with a timestamp and updates the LAST_ALERT time.
# -----------------------------------------------------------------------------
send_alert() {
    local subject=\$1
    local body=\$2
    echo -e "\$body" | mail -s "URGENT: \$subject" "\$EMAIL"
    echo "\$(date) - ALERT: \$subject" >> "\$LOG_FILE"
    LAST_ALERT=\$(date +%s)
}

# -----------------------------------------------------------------------------
# Function: generate_daily_report
#
# Purpose:
#   Generates a daily server report including system overview, web traffic,
#   daily alerts, top processes, and security checks.
#   The report is then sent via email using the send_alert function.
# -----------------------------------------------------------------------------
generate_daily_report() {
    report=$(cat <<EOF
DAILY SERVER REPORT - \$(date '+%A, %B %d %Y %H:%M:%S')

--- System Overview ---
\$(uptime)

--- Web Traffic ---
\$(tail -5000 /var/log/\${web_server}/access.log | awk '{print \$9}' | sort | uniq -c | sort -nr)

--- Daily Alerts ---
\$(grep "ALERT: " "\$LOG_FILE" | grep "\$(date +%Y-%m-%d)")

--- Top Processes ---
\$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n15)

--- Security Checks ---
\$(grep -i 'fail' /var/log/auth.log | tail -n5)
EOF
)
    send_alert "Daily Server Report - \$(hostname)" "\$report"
}

# -----------------------------------------------------------------------------
# Main Monitoring Loop
#
# Purpose:
#   Continuously monitor server load. If the load exceeds the defined threshold
#   and the cooldown period has passed, gather diagnostics and send an alert.
#
#   Also, at the specified daily report time, generate and send the daily report.
# -----------------------------------------------------------------------------
while true; do
    CURRENT_LOAD=\$(awk '{print \$1}' /proc/loadavg | cut -d. -f1)
    CURRENT_TIME=\$(date +%H:%M)
    
    # Load Spike Detection: Trigger an alert if the current load exceeds the threshold.
    if [ "\$CURRENT_LOAD" -ge "\$LOAD_THRESHOLD" ]; then
        if [ \$(( \$(date +%s) - LAST_ALERT )) -ge "\$ALERT_COOLDOWN" ]; then
            web_diag=\$(get_web_diagnostics)
            alert_msg="Load: \$CURRENT_LOAD\n\$(top -bn1 | head -20)\n\$web_diag"
            send_alert "Load Spike: \$CURRENT_LOAD - \$(hostname)" "\$alert_msg"
        fi
    fi
    
    # Daily Report: Check if the current time matches REPORT_TIME, then send the report.
    if [ "\$CURRENT_TIME" == "\$REPORT_TIME" ]; then
        generate_daily_report
        sleep 60  # Prevent duplicate reports within the same minute.
    fi
    
    sleep "\$CHECK_INTERVAL"
done
