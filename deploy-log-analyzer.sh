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

# Prompt for configuration
echo -e "${YELLOW}Configuration Setup${NC}"
echo ""
read -p "Enter OpenAI API Key: " OPENAI_API_KEY
read -p "Enter OpenAI Prompt ID (or leave empty to use inline prompt): " OPENAI_PROMPT_ID
read -p "Enter Keep API URL [https://api.keephq-cjm9.consultic.tech/alerts/event]: " KEEP_URL
KEEP_URL=${KEEP_URL:-https://api.keephq-cjm9.consultic.tech/alerts/event}
read -p "Enter Keep API Key: " KEEP_API_KEY
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

read -p "Enter ClickHouse Host [$DEFAULT_CH_HOST]: " CH_HOST
CH_HOST=${CH_HOST:-$DEFAULT_CH_HOST}
read -p "Enter ClickHouse Port [$DEFAULT_CH_PORT]: " CH_PORT
CH_PORT=${CH_PORT:-$DEFAULT_CH_PORT}
read -p "Enter Analysis Interval in Minutes [60]: " INTERVAL_MINUTES
INTERVAL_MINUTES=${INTERVAL_MINUTES:-60}

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
echo -e "${YELLOW}Step 4: Creating configuration...${NC}"

cat > /opt/log-analyzer/.env << EOFENV
# OpenAI Configuration
OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_PROMPT_ID=${OPENAI_PROMPT_ID}

# Keep Configuration
KEEP_URL=${KEEP_URL}
KEEP_API_KEY=${KEEP_API_KEY}

# ClickHouse Configuration
CLICKHOUSE_HOST=${CH_HOST}
CLICKHOUSE_PORT=${CH_PORT}
CLICKHOUSE_DATABASE=signoz_logs

# Analysis Configuration
ANALYSIS_INTERVAL_MINUTES=${INTERVAL_MINUTES}
EOFENV

chmod 600 /opt/log-analyzer/.env
echo -e "${GREEN}✓ Configuration saved${NC}"

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
import requests
from datetime import datetime, timedelta
from clickhouse_driver import Client
from openai import OpenAI
from dotenv import load_dotenv

# Load environment variables
load_dotenv('/opt/log-analyzer/.env')

# Configuration
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY')
OPENAI_PROMPT_ID = os.getenv('OPENAI_PROMPT_ID', '')
KEEP_URL = os.getenv('KEEP_URL')
KEEP_API_KEY = os.getenv('KEEP_API_KEY')
CH_HOST = os.getenv('CLICKHOUSE_HOST', 'clickhouse')
CH_PORT = int(os.getenv('CLICKHOUSE_PORT', '9000'))
CH_DATABASE = os.getenv('CLICKHOUSE_DATABASE', 'signoz_logs')
INTERVAL_MINUTES = int(os.getenv('ANALYSIS_INTERVAL_MINUTES', '60'))

# System prompt for log analysis (used if no prompt_id)
SYSTEM_PROMPT = """You are an expert log analyzer for production systems. 
Analyze the provided logs and identify:
1. Critical errors and failures
2. Recurring patterns that indicate systemic issues
3. Security concerns or anomalies
4. Performance degradation indicators
5. Any unusual or suspicious activity

Provide a structured summary with:
- Severity level (critical/high/warning/info)
- Number of critical incidents
- Top issues with counts
- Recommended actions

Format your response as JSON with this structure:
{
  "severity": "critical|high|warning|info",
  "summary": "Brief overview",
  "critical_count": 0,
  "error_count": 0,
  "warning_count": 0,
  "top_issues": [
    {"issue": "description", "count": 0, "severity": "critical|high|warning"}
  ],
  "recommendations": ["action 1", "action 2"],
  "notable_events": ["event 1", "event 2"]
}
"""

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
    
    query = f"""
    SELECT 
        timestamp,
        severity_text,
        severity_number,
        body,
        resources_string_key,
        resources_string_value
    FROM {CH_DATABASE}.logs
    WHERE timestamp >= {start_ns} AND timestamp <= {end_ns}
    ORDER BY timestamp DESC
    LIMIT 10000
    """
    
    try:
        print(f"[INFO] Querying logs from {start_time} to {end_time}")
        result = client.execute(query)
        print(f"[INFO] Retrieved {len(result)} log entries")
        return result
    except Exception as e:
        print(f"[ERROR] Failed to query logs: {e}")
        return []

def format_logs_for_analysis(logs):
    """Format logs into a readable text for AI analysis"""
    
    if not logs:
        return "No logs found in the specified time range."
    
    formatted_lines = []
    formatted_lines.append(f"Log Analysis Report - {datetime.utcnow().isoformat()}")
    formatted_lines.append(f"Total Entries: {len(logs)}")
    formatted_lines.append("=" * 80)
    formatted_lines.append("")
    
    # Group by severity
    severity_counts = {}
    
    for log in logs:
        timestamp, severity_text, severity_number, body, res_keys, res_values = log
        
        # Count by severity
        severity_counts[severity_text] = severity_counts.get(severity_text, 0) + 1
        
        # Convert timestamp
        try:
            ts = datetime.fromtimestamp(timestamp / 1e9).strftime('%Y-%m-%d %H:%M:%S')
        except:
            ts = "unknown"
        
        # Parse resource attributes
        host = "unknown"
        service = "unknown"
        if res_keys and res_values:
            for i, key in enumerate(res_keys):
                if key == 'host.name' and i < len(res_values):
                    host = res_values[i]
                elif key == 'service.name' and i < len(res_values):
                    service = res_values[i]
        
        # Format body
        body_str = str(body)
        if len(body_str) > 200:
            body_str = body_str[:200] + "..."
        
        formatted_lines.append(f"[{ts}] {severity_text} | {host} | {service}")
        formatted_lines.append(f"  {body_str}")
        formatted_lines.append("")
    
    # Add summary at the top
    summary_lines = ["", "Severity Summary:"]
    for severity, count in sorted(severity_counts.items()):
        summary_lines.append(f"  {severity}: {count}")
    summary_lines.append("=" * 80)
    summary_lines.append("")
    
    # Insert summary after header
    formatted_lines[4:4] = summary_lines
    
    return "\n".join(formatted_lines)

def analyze_with_openai(log_text):
    """Send logs to OpenAI for analysis"""
    
    try:
        client = OpenAI(api_key=OPENAI_API_KEY)
        
        print(f"[INFO] Sending {len(log_text)} characters to OpenAI for analysis")
        
        # Build messages based on whether Prompt ID is provided
        if OPENAI_PROMPT_ID:
            # Using platform-side prompt - send only user message
            print(f"[INFO] Using OpenAI platform prompt (ID: {OPENAI_PROMPT_ID})")
            print("[INFO] No system prompt in API call - managed on platform side")
            
            messages = [
                {
                    "role": "user",
                    "content": log_text
                }
            ]
            
            # Note: If using Assistants API or fine-tuned models,
            # you may need to use a different endpoint or pass the prompt ID differently
            # This assumes the prompt is configured in your OpenAI project settings
            
        else:
            # No Prompt ID - use inline system prompt as fallback
            print("[INFO] Using inline system prompt (no Prompt ID provided)")
            
            messages = [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": log_text}
            ]
        
        # Make API call
        response = client.chat.completions.create(
            model="gpt-4o",  # or gpt-4-turbo, gpt-3.5-turbo
            messages=messages,
            temperature=0.3,
            max_tokens=2000,
            response_format={"type": "json_object"}
        )
        
        analysis = response.choices[0].message.content
        print("[INFO] Received analysis from OpenAI")
        
        # Parse JSON response
        try:
            analysis_data = json.loads(analysis)
            return analysis_data
        except json.JSONDecodeError:
            # If not valid JSON, wrap it
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
    
    # Build Keep alert
    keep_alert = {
        "id": f"ai-analysis-{int(datetime.utcnow().timestamp())}",
        "name": f"AI Log Analysis: {analysis.get('summary', 'System Analysis')[:80]}",
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
    
    # Step 2: Query logs
    print(f"[2/4] Querying logs for last {INTERVAL_MINUTES} minutes...")
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

