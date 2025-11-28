#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Deploy AI Log Analyzer Service${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# Check if root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: Please run as root (use sudo)${NC}"
    exit 1
fi

# Check for existing .env file first
mkdir -p /opt/log-analyzer

if [ -f /opt/log-analyzer/.env ]; then
    echo -e "${GREEN}✓ Found existing .env file. Loading configuration...${NC}"
    # Source the .env file to load variables
    set -a
    source /opt/log-analyzer/.env
    set +a
    
    # Extract values (handle comments and empty lines)
    OPENAI_API_KEY=${OPENAI_API_KEY:-}
    OPENAI_PROMPT_ID=${OPENAI_PROMPT_ID:-}
    OPENAI_PROMPT_VERSION=${OPENAI_PROMPT_VERSION:-}
    KEEP_URL=${KEEP_URL:-}
    KEEP_API_KEY=${KEEP_API_KEY:-}
    CH_HOST=${CLICKHOUSE_HOST:-clickhouse}
    CH_PORT=${CLICKHOUSE_PORT:-9000}
    CH_DATABASE=${CLICKHOUSE_DATABASE:-signoz_logs}
    INTERVAL_MINUTES=${ANALYSIS_INTERVAL_MINUTES:-${INTERVAL_MINUTES:-10}}
    MIN_LOG_SEVERITY=${MIN_LOG_SEVERITY:-13}
    
    echo -e "${GREEN}✓ Configuration loaded from existing .env file${NC}"
    echo ""
    echo "Current configuration:"
    echo "  OpenAI Prompt ID: ${OPENAI_PROMPT_ID:-'(not set)'}"
    echo "  OpenAI Prompt Version: ${OPENAI_PROMPT_VERSION:-'(not set)'}"
    echo "  ClickHouse: ${CH_HOST}:${CH_PORT}"
    echo "  Database: ${CH_DATABASE}"
    echo "  Interval: ${INTERVAL_MINUTES} minutes"
    echo "  Min Log Severity: ${MIN_LOG_SEVERITY} (13=WARN, 17=ERROR, 21=FATAL)"
    echo ""
    read -p "Do you want to update any values? (y/N): " UPDATE_CONFIG
    if [ "$UPDATE_CONFIG" = "y" ] || [ "$UPDATE_CONFIG" = "Y" ]; then
        SKIP_ENV_CREATE=false
    else
        SKIP_ENV_CREATE=true
        # Still allow updating prompt version
        read -p "Enter OpenAI Prompt Version to update (optional, press Enter to skip): " NEW_PROMPT_VERSION
        if [ -n "$NEW_PROMPT_VERSION" ]; then
            if grep -q "^OPENAI_PROMPT_VERSION=" /opt/log-analyzer/.env; then
                sed -i "s/^OPENAI_PROMPT_VERSION=.*/OPENAI_PROMPT_VERSION=${NEW_PROMPT_VERSION}/" /opt/log-analyzer/.env
            else
                echo "OPENAI_PROMPT_VERSION=${NEW_PROMPT_VERSION}" >> /opt/log-analyzer/.env
            fi
            OPENAI_PROMPT_VERSION=$NEW_PROMPT_VERSION
            echo -e "${GREEN}✓ Updated OPENAI_PROMPT_VERSION${NC}"
        fi
        # Ensure MIN_LOG_SEVERITY exists in .env (add if missing)
        if ! grep -q "^MIN_LOG_SEVERITY=" /opt/log-analyzer/.env; then
            echo "MIN_LOG_SEVERITY=${MIN_LOG_SEVERITY:-13}" >> /opt/log-analyzer/.env
            echo -e "${GREEN}✓ Added MIN_LOG_SEVERITY to .env${NC}"
        fi
    fi
else
    echo -e "${YELLOW}No existing .env file found. Will prompt for configuration.${NC}"
    SKIP_ENV_CREATE=false
fi

# Prompt for configuration only if .env doesn't exist or user wants to update
if [ "$SKIP_ENV_CREATE" != "true" ]; then
    echo ""
    echo -e "${YELLOW}Configuration Setup${NC}"
    echo ""
    read -p "Enter OpenAI API Key${OPENAI_API_KEY:+ [current: ${OPENAI_API_KEY:0:10}...]}: " NEW_OPENAI_API_KEY
    OPENAI_API_KEY=${NEW_OPENAI_API_KEY:-$OPENAI_API_KEY}
    
    read -p "Enter OpenAI Prompt ID${OPENAI_PROMPT_ID:+ [current: $OPENAI_PROMPT_ID]}: " NEW_OPENAI_PROMPT_ID
    OPENAI_PROMPT_ID=${NEW_OPENAI_PROMPT_ID:-$OPENAI_PROMPT_ID}
    
    DEFAULT_KEEP_URL="https://api.keephq-cjm9.consultic.tech/alerts/event"
    read -p "Enter Keep API URL${KEEP_URL:+ [current: $KEEP_URL]} [$DEFAULT_KEEP_URL]: " NEW_KEEP_URL
    KEEP_URL=${NEW_KEEP_URL:-${KEEP_URL:-$DEFAULT_KEEP_URL}}
    
    read -p "Enter Keep API Key${KEEP_API_KEY:+ [current: ${KEEP_API_KEY:0:10}...]}: " NEW_KEEP_API_KEY
    KEEP_API_KEY=${NEW_KEEP_API_KEY:-$KEEP_API_KEY}
    
    echo ""
    echo -e "${YELLOW}Detecting ClickHouse configuration...${NC}"
    
    # Auto-detect ClickHouse connection
    if docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep clickhouse | grep -q "0.0.0.0:9000"; then
        echo -e "${GREEN}✓ Found ClickHouse on localhost:9000 (port exposed)${NC}"
        DEFAULT_CH_HOST="localhost"
        DEFAULT_CH_PORT="9000"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q clickhouse; then
        # Try to get IP from any network (custom networks have nested IPAddress)
        CH_IP=$(docker inspect signoz-clickhouse 2>/dev/null | grep '"IPAddress"' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^$' | head -1)
        
        if [ -n "$CH_IP" ]; then
            echo -e "${YELLOW}⚠ ClickHouse port not exposed, using container IP: $CH_IP${NC}"
            echo -e "${YELLOW}  Consider exposing port 9000 in docker-compose.yaml for better reliability${NC}"
            DEFAULT_CH_HOST="$CH_IP"
            DEFAULT_CH_PORT="9000"
        else
            echo -e "${YELLOW}⚠ Could not auto-detect ClickHouse IP${NC}"
            echo -e "${YELLOW}  Please check: docker inspect signoz-clickhouse | grep IPAddress${NC}"
            DEFAULT_CH_HOST="localhost"
            DEFAULT_CH_PORT="9000"
        fi
    else
        echo -e "${YELLOW}⚠ ClickHouse container not found${NC}"
        DEFAULT_CH_HOST="localhost"
        DEFAULT_CH_PORT="9000"
    fi
    
    DEFAULT_CH_HOST=${CH_HOST:-$DEFAULT_CH_HOST}
    DEFAULT_CH_PORT=${CH_PORT:-$DEFAULT_CH_PORT}
    read -p "Enter ClickHouse Host [$DEFAULT_CH_HOST]: " NEW_CH_HOST
    CH_HOST=${NEW_CH_HOST:-$DEFAULT_CH_HOST}
    read -p "Enter ClickHouse Port [$DEFAULT_CH_PORT]: " NEW_CH_PORT
    CH_PORT=${NEW_CH_PORT:-$DEFAULT_CH_PORT}
    
    DEFAULT_INTERVAL=${INTERVAL_MINUTES:-10}
    read -p "Enter Analysis Interval in Minutes [$DEFAULT_INTERVAL]: " NEW_INTERVAL_MINUTES
    INTERVAL_MINUTES=${NEW_INTERVAL_MINUTES:-$DEFAULT_INTERVAL}
    
    DEFAULT_MIN_SEVERITY=${MIN_LOG_SEVERITY:-13}
    echo ""
    echo "Log Severity Levels:"
    echo "  1-4 = TRACE, 5-8 = DEBUG, 9-12 = INFO"
    echo "  13-16 = WARN, 17-20 = ERROR, 21-24 = FATAL"
    read -p "Enter Minimum Log Severity (13=WARN, 17=ERROR, 21=FATAL) [$DEFAULT_MIN_SEVERITY]: " NEW_MIN_SEVERITY
    MIN_LOG_SEVERITY=${NEW_MIN_SEVERITY:-$DEFAULT_MIN_SEVERITY}
    
    CH_DATABASE=${CH_DATABASE:-signoz_logs}
fi

echo ""
echo -e "${YELLOW}Step 1: Installing dependencies...${NC}"
apt-get update -qq
apt-get install -y python3 python3-pip python3-venv

echo -e "${GREEN}✓ Dependencies installed${NC}"

# Create directory
echo ""
echo -e "${YELLOW}Step 2: Creating application directory...${NC}"
mkdir -p /opt/log-analyzer
cd /opt/log-analyzer

# Create virtual environment
echo -e "${YELLOW}Step 3: Setting up Python virtual environment...${NC}"
python3 -m venv venv
source venv/bin/activate

# Install Python packages
pip install --quiet --upgrade pip
pip install --quiet requests clickhouse-driver openai python-dotenv

echo -e "${GREEN}✓ Virtual environment ready${NC}"

# Create configuration file
echo ""
echo -e "${YELLOW}Step 4: Creating/updating configuration...${NC}"

if [ "$SKIP_ENV_CREATE" != "true" ]; then
    # Backup existing .env if it exists and we're about to overwrite
    if [ -f /opt/log-analyzer/.env ]; then
        BACKUP_FILE="/opt/log-analyzer/.env.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}⚠ Backing up existing .env to: ${BACKUP_FILE}${NC}"
        cp /opt/log-analyzer/.env "$BACKUP_FILE"
        echo -e "${GREEN}✓ Backup created${NC}"
    fi
    
    read -p "Enter OpenAI Prompt Version (optional, press Enter to skip): " NEW_PROMPT_VERSION
    OPENAI_PROMPT_VERSION=${NEW_PROMPT_VERSION:-$OPENAI_PROMPT_VERSION}

    cat > /opt/log-analyzer/.env << EOFENV
# OpenAI Configuration
OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_PROMPT_ID=${OPENAI_PROMPT_ID}
OPENAI_PROMPT_VERSION=${OPENAI_PROMPT_VERSION}

# Keep Configuration
KEEP_URL=${KEEP_URL}
KEEP_API_KEY=${KEEP_API_KEY}

# ClickHouse Configuration
CLICKHOUSE_HOST=${CH_HOST}
CLICKHOUSE_PORT=${CH_PORT}
CLICKHOUSE_DATABASE=signoz_logs

# Analysis Configuration
ANALYSIS_INTERVAL_MINUTES=${INTERVAL_MINUTES}
MIN_LOG_SEVERITY=${MIN_LOG_SEVERITY:-13}
EOFENV

    chmod 600 /opt/log-analyzer/.env
    echo -e "${GREEN}✓ Configuration saved${NC}"
else
    echo -e "${GREEN}✓ Using existing .env configuration${NC}"
fi

# Create application file
echo ""
echo -e "${YELLOW}Step 5: Installing application...${NC}"

cat > /opt/log-analyzer/analyzer.py << 'EOFAPP'
#!/usr/bin/env python3
"""
AI-Powered Log Analyzer for SigNoz
Queries ClickHouse hourly, analyzes logs with OpenAI Agents, and reports to Keep
"""

import os
import sys
import json
import socket
import requests
from datetime import datetime, timedelta
from clickhouse_driver import Client
from openai import OpenAI
from dotenv import load_dotenv

# Load environment variables
load_dotenv('/opt/log-analyzer/.env')

# Configuration
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY')
OPENAI_PROMPT_ID = os.getenv('OPENAI_PROMPT_ID', '')  # Prompt ID from OpenAI platform
OPENAI_PROMPT_VERSION = os.getenv('OPENAI_PROMPT_VERSION', '')  # Optional: prompt version
KEEP_URL = os.getenv('KEEP_URL')
KEEP_API_KEY = os.getenv('KEEP_API_KEY')
CH_HOST = os.getenv('CLICKHOUSE_HOST', 'clickhouse')
CH_PORT = int(os.getenv('CLICKHOUSE_PORT', '9000'))
CH_DATABASE = os.getenv('CLICKHOUSE_DATABASE', 'signoz_logs')
INTERVAL_MINUTES = int(os.getenv('ANALYSIS_INTERVAL_MINUTES', os.getenv('INTERVAL_MINUTES', '10')))
MIN_LOG_SEVERITY = int(os.getenv('MIN_LOG_SEVERITY', '13'))

def get_clickhouse_client():
    """Create ClickHouse client"""
    try:
        client = Client(
            host=CH_HOST,
            port=CH_PORT,
            database=CH_DATABASE
        )
        return client
    except Exception as e:
        print(f"[ERROR] Failed to connect to ClickHouse: {e}")
        sys.exit(1)

def query_logs(client, lookback_minutes):
    """Query logs from ClickHouse for the last N minutes"""
    
    # Calculate time range
    end_time = datetime.utcnow()
    start_time = end_time - timedelta(minutes=lookback_minutes)
    
    # Convert to nanoseconds (ClickHouse uses UInt64 for timestamp)
    start_ns = int(start_time.timestamp() * 1e9)
    end_ns = int(end_time.timestamp() * 1e9)
    
    # Filter by minimum severity level (from .env)
    # TRACE=1-4, DEBUG=5-8, INFO=9-12, WARN=13-16, ERROR=17-20, FATAL=21-24
    query = f"""
    SELECT 
        timestamp,
        severity_text,
        severity_number,
        body,
        resources_string
    FROM {CH_DATABASE}.logs_v2
    WHERE timestamp >= {start_ns} AND timestamp <= {end_ns}
      AND severity_number >= {MIN_LOG_SEVERITY}
    ORDER BY timestamp DESC
    LIMIT 10000
    """
    
    try:
        severity_names = {13: "WARN", 17: "ERROR", 21: "FATAL"}
        severity_name = severity_names.get(MIN_LOG_SEVERITY, f"severity>={MIN_LOG_SEVERITY}")
        print(f"[INFO] Querying logs from {start_time} to {end_time} (severity >= {MIN_LOG_SEVERITY} ({severity_name} and above))")
        result = client.execute(query)
        print(f"[INFO] Retrieved {len(result)} log entries with severity >= {MIN_LOG_SEVERITY}")
        return result
    except Exception as e:
        print(f"[ERROR] Failed to query logs: {e}")
        return []

def format_logs_for_analysis(logs):
    """Format logs into a readable text for AI analysis"""
    
    if not logs:
        return "No logs found in the specified time range."
    
    # Token limit: aim for ~30k tokens max (~120k characters)
    # gpt-4o supports 128k tokens, but leave room for response
    MAX_CHARS = 120000
    MAX_BODY_LENGTH = 2000  # Reduced from 200 to fit more logs
    
    formatted_lines = []
    formatted_lines.append(f"Log Analysis Report - {datetime.utcnow().isoformat()}")
    formatted_lines.append(f"Total Entries: {len(logs)}")
    formatted_lines.append("=" * 80)
    formatted_lines.append("")
    
    # Group by severity
    severity_counts = {}
    for log in logs:
        severity_counts[log[1]] = severity_counts.get(log[1], 0) + 1
    
    # Add summary at the top
    summary_lines = ["", "Severity Summary:"]
    for severity, count in sorted(severity_counts.items()):
        summary_lines.append(f"  {severity}: {count}")
    summary_lines.append("=" * 80)
    summary_lines.append("")
    
    # Insert summary after header
    formatted_lines[4:4] = summary_lines
    
    # Format logs with size tracking
    current_size = len("\n".join(formatted_lines))
    logs_added = 0
    logs_skipped = 0
    
    for log in logs:
        timestamp, severity_text, severity_number, body, resources_string = log
        
        # Convert timestamp
        try:
            ts = datetime.fromtimestamp(timestamp / 1e9).strftime('%Y-%m-%d %H:%M:%S')
        except:
            ts = "unknown"
        
        # Parse resource attributes
        host = "unknown"
        service = "unknown"
        if resources_string and isinstance(resources_string, dict):
            host = resources_string.get('host.name', 'unknown')
            service = resources_string.get('service.name', 'unknown')
        
        # Format body
        body_str = str(body)
        if len(body_str) > MAX_BODY_LENGTH:
            body_str = body_str[:MAX_BODY_LENGTH] + "..."
        
        # Build log entry
        log_entry = f"[{ts}] {severity_text} | {host} | {service}\n  {body_str}\n"
        
        # Check if adding this log would exceed limit
        if current_size + len(log_entry) > MAX_CHARS:
            logs_skipped += 1
            continue
        
        formatted_lines.append(f"[{ts}] {severity_text} | {host} | {service}")
        formatted_lines.append(f"  {body_str}")
        formatted_lines.append("")
        current_size += len(log_entry)
        logs_added += 1
    
    # Add truncation notice if needed
    if logs_skipped > 0:
        formatted_lines.append("")
        formatted_lines.append(f"[NOTE: {logs_skipped} additional log entries omitted due to size limits]")
        formatted_lines.append(f"[Showing {logs_added} of {len(logs)} total entries]")
    
    result = "\n".join(formatted_lines)
    print(f"[DEBUG] Formatted logs: {len(result)} characters, {logs_added} logs included, {logs_skipped} skipped")
    
    return result

def analyze_with_openai(log_text):
    """Send logs to OpenAI for analysis using Responses API"""
    
    try:
        client = OpenAI(api_key=OPENAI_API_KEY)
        
        print(f"[INFO] Sending {len(log_text)} characters to OpenAI for analysis")
        print(f"[INFO] Using Responses API with platform prompt ID: {OPENAI_PROMPT_ID}")
        
        # Build prompt parameter
        prompt_config = {"id": OPENAI_PROMPT_ID}
        if OPENAI_PROMPT_VERSION:
            prompt_config["version"] = OPENAI_PROMPT_VERSION
        
        # When using json_object format, input must contain the word "json"
        # Add a simple prefix to satisfy this requirement
        input_with_json_hint = f"Analyze and return JSON:\n\n{log_text}"
        
        # Log request details
        print(f"[DEBUG] ======== OpenAI Request ========")
        print(f"[DEBUG] URL: https://api.openai.com/v1/responses")
        print(f"[DEBUG] Method: POST")
        print(f"[DEBUG] Payload:")
        print(f"[DEBUG]   prompt.id: {OPENAI_PROMPT_ID}")
        if OPENAI_PROMPT_VERSION:
            print(f"[DEBUG]   prompt.version: {OPENAI_PROMPT_VERSION}")
        print(f"[DEBUG]   input: (length={len(input_with_json_hint)}) '{input_with_json_hint[:200]}...'")
        print(f"[DEBUG]   text.format.type: json_object")
        print(f"[DEBUG]   store: True")
        
        print(f"[DEBUG] Making API call to OpenAI...")
        response = client.responses.create(
            prompt=prompt_config,
            input=input_with_json_hint,
            text={
                "format": {
                    "type": "json_object"
                }
            },
            store=True  # Store to see in OpenAI platform
        )
        
        # Log response details
        print(f"[DEBUG] ======== OpenAI Response ========")
        print(f"[DEBUG] Response ID: {response.id}")
        print(f"[DEBUG] Status: {response.status}")
        print(f"[DEBUG] Model: {response.model}")
        print(f"[DEBUG] Created: {response.created_at}")
        
        # Log usage if available
        if hasattr(response, 'usage') and response.usage:
            print(f"[DEBUG] Usage: {response.usage}")
        
        # Extract output from Responses API
        # Use the output_text helper for easy access
        analysis = response.output_text
        
        print(f"[DEBUG] Output text length: {len(analysis)} characters")
        print(f"[DEBUG] Output text (full): {analysis}")
        print(f"[INFO] Received analysis from OpenAI Responses API")
        
        # Parse JSON response
        try:
            analysis_data = json.loads(analysis)
            return analysis_data
        except json.JSONDecodeError:
            # If not valid JSON, wrap it
            print("[WARN] Response was not valid JSON, wrapping...")
            return {
                "severity": "info",
                "summary": analysis,
                "critical_count": 0,
                "error_count": 0,
                "warning_count": 0,
                "top_issues": [],
                "recommendations": [],
                "notable_events": []
            }
    
    except Exception as e:
        print(f"[ERROR] OpenAI analysis failed: {e}")
        import traceback
        traceback.print_exc()
        return None

def send_to_keep(analysis, log_count, time_range_minutes):
    """Send analysis results to Keep as an alert"""
    
    if not analysis:
        print("[WARN] No analysis to send to Keep")
        return False
    
    # Determine severity
    severity = analysis.get('severity', 'info')
    critical_count = analysis.get('critical_count', 0)
    error_count = analysis.get('error_count', 0)
    
    # Determine status
    if critical_count > 0 or severity == 'critical':
        status = 'firing'
    elif error_count > 5 or severity in ['high', 'warning']:
        status = 'firing'
    else:
        status = 'resolved'
    
    # Build description
    description_parts = [
        f"AI Analysis Summary (Last {time_range_minutes} minutes):",
        "",
        analysis.get('summary', 'No summary provided'),
        "",
        f"Metrics:",
        f"  • Total logs analyzed: {log_count}",
        f"  • Critical events: {critical_count}",
        f"  • Errors: {error_count}",
        f"  • Warnings: {analysis.get('warning_count', 0)}",
    ]
    
    # Add top issues
    top_issues = analysis.get('top_issues', [])
    if top_issues:
        description_parts.append("")
        description_parts.append("Top Issues:")
        for issue in top_issues[:5]:
            description_parts.append(f"  • [{issue.get('severity', 'info').upper()}] {issue.get('issue', 'Unknown')} (×{issue.get('count', 0)})")
    
    # Add recommendations
    recommendations = analysis.get('recommendations', [])
    if recommendations:
        description_parts.append("")
        description_parts.append("Recommendations:")
        for rec in recommendations[:5]:
            description_parts.append(f"  • {rec}")
    
    # Add notable events
    notable_events = analysis.get('notable_events', [])
    if notable_events:
        description_parts.append("")
        description_parts.append("Notable Events:")
        for event in notable_events[:5]:
            description_parts.append(f"  • {event}")
    
    full_description = '\n'.join(description_parts)
    
    # Get hostname for alert identification
    hostname = socket.gethostname()
    
    # Build Keep alert
    analysis_summary = analysis.get('summary', 'System Analysis')[:80]
    keep_alert = {
        "id": f"ai-analysis-{int(datetime.utcnow().timestamp())}",
        "name": f"[{hostname}] AI Log Analysis: {analysis_summary}",
        "status": status,
        "severity": severity,
        "lastReceived": datetime.utcnow().isoformat() + 'Z',
        "message": analysis.get('summary', 'AI-powered log analysis completed'),
        "description": full_description,
        "source": ["signoz", "ai-analyzer"],
        "service": "log-analyzer",
        "labels": {
            "analyzer": "openai",
            "log_count": str(log_count),
            "critical_count": str(critical_count),
            "error_count": str(error_count),
            "time_range_minutes": str(time_range_minutes),
            "analysis_timestamp": datetime.utcnow().isoformat()
        }
    }
    
    try:
        print(f"[INFO] Sending alert to Keep: {KEEP_URL}")
        response = requests.post(
            KEEP_URL,
            headers={
                'X-API-KEY': KEEP_API_KEY,
                'Content-Type': 'application/json',
                'Accept': 'application/json'
            },
            json=keep_alert,
            timeout=30
        )
        
        if response.status_code in [200, 201, 202]:
            print(f"[SUCCESS] Alert sent to Keep: {response.status_code}")
            return True
        else:
            print(f"[ERROR] Keep returned {response.status_code}: {response.text[:200]}")
            return False
    
    except Exception as e:
        print(f"[ERROR] Failed to send to Keep: {e}")
        return False

def main():
    """Main execution function"""
    print("=" * 80)
    print("AI-Powered Log Analyzer for SigNoz")
    print("=" * 80)
    print(f"Timestamp: {datetime.utcnow().isoformat()}")
    print(f"Analysis Window: Last {INTERVAL_MINUTES} minutes")
    print("")
    
    # Step 1: Connect to ClickHouse
    print("[1/4] Connecting to ClickHouse...")
    client = get_clickhouse_client()
    print("[SUCCESS] Connected to ClickHouse")
    
    # Step 2: Query logs (filtered by minimum severity)
    severity_names = {13: "WARN", 17: "ERROR", 21: "FATAL"}
    severity_name = severity_names.get(MIN_LOG_SEVERITY, f"severity>={MIN_LOG_SEVERITY}")
    print(f"[2/4] Querying logs (severity >= {MIN_LOG_SEVERITY} - {severity_name} and above) for last {INTERVAL_MINUTES} minutes...")
    logs = query_logs(client, INTERVAL_MINUTES)
    
    if not logs or len(logs) == 0:
        print("[WARN] No logs found. Sending info alert to Keep.")
        analysis = {
            "severity": "info",
            "summary": f"No logs found in the last {INTERVAL_MINUTES} minutes",
            "critical_count": 0,
            "error_count": 0,
            "warning_count": 0,
            "top_issues": [],
            "recommendations": ["Check if log collection is working properly"],
            "notable_events": []
        }
        send_to_keep(analysis, 0, INTERVAL_MINUTES)
        return
    
    # Step 3: Analyze with OpenAI
    print(f"[3/4] Analyzing {len(logs)} logs with OpenAI...")
    log_text = format_logs_for_analysis(logs)
    
    # Save formatted logs for debugging
    with open('/opt/log-analyzer/last_analysis.txt', 'w') as f:
        f.write(log_text)
    print("[DEBUG] Formatted logs saved to /opt/log-analyzer/last_analysis.txt")
    
    analysis = analyze_with_openai(log_text)
    
    if analysis:
        # Save analysis for debugging
        with open('/opt/log-analyzer/last_analysis.json', 'w') as f:
            json.dump(analysis, f, indent=2)
        print("[DEBUG] Analysis saved to /opt/log-analyzer/last_analysis.json")
        
        # Step 4: Send to Keep
        print("[4/4] Sending results to Keep...")
        success = send_to_keep(analysis, len(logs), INTERVAL_MINUTES)
        
        if success:
            print("")
            print("=" * 80)
            print("[SUCCESS] Analysis completed and sent to Keep!")
            print("=" * 80)
        else:
            print("")
            print("=" * 80)
            print("[WARN] Analysis completed but failed to send to Keep")
            print("=" * 80)
            sys.exit(1)
    else:
        print("[ERROR] Analysis failed")
        sys.exit(1)

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n[INFO] Interrupted by user")
        sys.exit(0)
    except Exception as e:
        print(f"\n[ERROR] Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
EOFAPP

chmod +x /opt/log-analyzer/analyzer.py
echo -e "${GREEN}✓ Application installed${NC}"

# Create systemd service
echo ""
echo -e "${YELLOW}Step 6: Creating systemd service...${NC}"

cat > /etc/systemd/system/log-analyzer.service << 'EOFSVC'
[Unit]
Description=AI Log Analyzer - Single Run
After=network.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/opt/log-analyzer
Environment="PATH=/opt/log-analyzer/venv/bin"
ExecStart=/opt/log-analyzer/venv/bin/python3 /opt/log-analyzer/analyzer.py
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFSVC

echo -e "${GREEN}✓ Service created${NC}"

# Create systemd timer
echo ""
echo -e "${YELLOW}Step 7: Creating systemd timer...${NC}"

cat > /etc/systemd/system/log-analyzer.timer << EOFTIMER
[Unit]
Description=AI Log Analyzer Timer - Run every ${INTERVAL_MINUTES} minutes
After=network.target

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL_MINUTES}min
Persistent=true

[Install]
WantedBy=timers.target
EOFTIMER

echo -e "${GREEN}✓ Timer created${NC}"

# Enable timer
echo ""
echo -e "${YELLOW}Step 8: Enabling timer...${NC}"
systemctl daemon-reload
systemctl enable log-analyzer.timer
systemctl start log-analyzer.timer

sleep 2

if systemctl is-active --quiet log-analyzer.timer; then
    echo -e "${GREEN}✓ Timer is active${NC}"
else
    echo -e "${RED}✗ Timer failed to start${NC}"
    systemctl status log-analyzer.timer
    exit 1
fi

# Test ClickHouse connection
echo ""
echo -e "${YELLOW}Step 9: Testing ClickHouse connection...${NC}"

# Simple Python test
/opt/log-analyzer/venv/bin/python3 << EOFTEST
import sys
try:
    from clickhouse_driver import Client
    client = Client(host='${CH_HOST}', port=${CH_PORT}, database='${CH_DATABASE}')
    result = client.execute('SELECT 1')
    print('✓ ClickHouse connection successful')
    sys.exit(0)
except Exception as e:
    print(f'✗ ClickHouse connection failed: {e}')
    print('')
    print('Troubleshooting:')
    print('  1. Check if ClickHouse port is exposed: docker ps | grep clickhouse')
    print('  2. See CLICKHOUSE_CONNECTION_GUIDE.md for solutions')
    print('  3. Edit /opt/log-analyzer/.env to fix the configuration')
    sys.exit(1)
EOFTEST

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}⚠ ClickHouse connection failed${NC}"
    echo -e "${YELLOW}Installation completed but service may not work until connection is fixed${NC}"
    echo -e "${YELLOW}See /opt/log-analyzer/.env to update configuration${NC}"
    echo ""
fi

# Test run
echo ""
echo -e "${YELLOW}Step 10: Running initial test...${NC}"
echo -e "${YELLOW}(This may take 30-60 seconds)${NC}"
systemctl start log-analyzer.service

sleep 3

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Service Information:"
echo "  Name: log-analyzer"
echo "  Interval: Every ${INTERVAL_MINUTES} minutes"
echo "  ClickHouse: ${CH_HOST}:${CH_PORT}"
echo "  Keep Endpoint: ${KEEP_URL}"
echo "  OpenAI Prompt ID: ${OPENAI_PROMPT_ID:-"(using inline prompt)"}"
echo ""
echo "Useful Commands:"
echo "  View timer status: systemctl status log-analyzer.timer"
echo "  View service status: systemctl status log-analyzer.service"
echo "  View logs: journalctl -u log-analyzer.service -f"
echo "  Manual run: systemctl start log-analyzer.service"
echo "  Stop timer: systemctl stop log-analyzer.timer"
echo "  Disable timer: systemctl disable log-analyzer.timer"
echo ""
echo "Debug Files:"
echo "  Last analysis input: /opt/log-analyzer/last_analysis.txt"
echo "  Last analysis output: /opt/log-analyzer/last_analysis.json"
echo "  Configuration: /opt/log-analyzer/.env"
echo ""
echo "Next Schedule:"
systemctl list-timers log-analyzer.timer --no-pager
echo ""
echo -e "${YELLOW}Check the logs in a moment to see the analysis results:${NC}"
echo "  journalctl -u log-analyzer.service -n 50"

