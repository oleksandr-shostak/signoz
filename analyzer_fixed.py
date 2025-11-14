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
OPENAI_PROMPT_ID = os.getenv('OPENAI_PROMPT_ID', '')  # Prompt ID from OpenAI platform
OPENAI_PROMPT_VERSION = os.getenv('OPENAI_PROMPT_VERSION', '')  # Optional: prompt version
KEEP_URL = os.getenv('KEEP_URL')
KEEP_API_KEY = os.getenv('KEEP_API_KEY')
CH_HOST = os.getenv('CLICKHOUSE_HOST', 'clickhouse')
CH_PORT = int(os.getenv('CLICKHOUSE_PORT', '9000'))
CH_DATABASE = os.getenv('CLICKHOUSE_DATABASE', 'signoz_logs')
INTERVAL_MINUTES = int(os.getenv('ANALYSIS_INTERVAL_MINUTES', os.getenv('INTERVAL_MINUTES', '10')))

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
        resources_string
    FROM {CH_DATABASE}.logs_v2
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
    
    # Token limit: aim for ~30k tokens max (~120k characters)
    # gpt-4o supports 128k tokens, but leave room for response
    MAX_CHARS = 120000
    MAX_BODY_LENGTH = 2000  # Allow longer log bodies for better analysis
    
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

