# Complete SigNoz AI Log Analyzer Deployment Guide

Complete guide to deploy SigNoz with AI-powered log analysis and Keep integration from scratch.

## 📋 Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Step 1: Deploy SigNoz](#step-1-deploy-signoz)
5. [Step 2: Deploy AI Log Analyzer](#step-2-deploy-ai-log-analyzer)
6. [Verification](#verification)
7. [Troubleshooting](#troubleshooting)

---

## Overview

This deployment creates a complete observability stack:

```
Windows Hosts → OpenTelemetry Collector → ClickHouse → AI Analyzer → Keep
     ↓                    ↓                    ↓            ↓          ↓
  Logs/Metrics      Processes & Stores    Stores Logs   Analyzes   Alerts
```

**What you get:**
- ✅ SigNoz for log collection and visualization
- ✅ AI-powered log analysis every 10 minutes
- ✅ Automated anomaly detection
- ✅ Alerts sent to Keep with severity and recommendations
- ✅ Full integration with OpenAI platform prompts

---

## Architecture

### Components

1. **SigNoz** - Open-source observability platform
   - ClickHouse database for log storage
   - OpenTelemetry Collector for log ingestion
   - Query service and frontend

2. **AI Log Analyzer** - Python service (this project)
   - Queries ClickHouse every 10 minutes
   - Sends logs to OpenAI for analysis
   - Publishes alerts to Keep

3. **Keep** - Alert management platform
   - Receives analysis results
   - Displays anomalies and recommendations
   - Can trigger workflows/notifications

### Data Flow

```
1. Windows hosts send logs via OpenTelemetry → SigNoz
2. Logs stored in ClickHouse (signoz_logs.logs_v2)
3. AI Analyzer runs every 10 minutes:
   - Queries last 10 minutes of logs
   - Formats and sends to OpenAI Responses API
   - Receives structured analysis (JSON)
   - Sends alert to Keep with severity
4. Keep displays alert with recommendations
```

---

## Prerequisites

### Required Accounts & Keys

1. **OpenAI Account**
   - API key (starts with `sk-proj-...`)
   - Create a stored prompt in OpenAI platform
   - Note your prompt ID (e.g., `pmpt_abc123...`)

2. **Keep Instance**
   - Keep API URL (e.g., `https://api.keephq-xxx.consultic.tech/alerts/event`)
   - Keep API key

3. **Server Requirements**
   - Ubuntu/Debian Linux server
   - Root/sudo access
   - 4GB+ RAM recommended
   - Docker and Docker Compose installed
   - Ports: 3301, 9000, 4317, 4318

### Files Needed

From this repository:
- `deploy-log-analyzer.sh` - Automated deployment script (contains all code)

---

## Step 1: Deploy SigNoz

### 1.1 Install Docker

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Install Docker Compose
sudo apt install docker-compose -y

# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### 1.2 Install SigNoz

```bash
# Clone SigNoz repository
git clone https://github.com/SigNoz/signoz.git
cd signoz/deploy

# Run installation
sudo ./install.sh
```

**Configuration prompts:**
- Choose installation type: Select "Docker Standalone"
- Accept default settings or customize as needed

### 1.3 Expose ClickHouse Port

Edit `docker-compose.yaml`:

```bash
nano docker-compose.yaml
```

Find the `clickhouse` service and add port mapping:

```yaml
clickhouse:
  image: clickhouse/clickhouse-server:24.1.2-alpine
  ports:
    - "9000:9000"  # Add this line
    - "8123:8123"
```

Restart services:

```bash
docker-compose down
docker-compose up -d
```

### 1.4 Verify SigNoz is Running

```bash
# Check all containers are running
docker ps

# Access SigNoz UI
# Open browser: http://your-server-ip:3301
```

---

## Step 2: Deploy AI Log Analyzer

### 2.1 Prepare OpenAI Platform

1. **Create a Stored Prompt** on OpenAI platform:
   - Go to OpenAI Platform → Your Project → Prompts
   - Create new prompt with these settings:

**Prompt Instructions:**
```
You are an expert log analyzer for production systems.

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
```

**Settings:**
- Model: `gpt-4o` (or `gpt-4-turbo`)
- Temperature: `0.3`
- Max Tokens: `2048`
- Response Format: JSON

2. **Save and copy the Prompt ID** (e.g., `pmpt_69158f49c30081978fefc0f93776ebfc078073f3992b13f0`)

### 2.2 Deploy the Analyzer Service

```bash
# Copy deployment script to server
scp deploy-log-analyzer.sh root@your-server:/tmp/

# SSH to server
ssh root@your-server

# Run deployment script
cd /tmp
chmod +x deploy-log-analyzer.sh
sudo ./deploy-log-analyzer.sh
```

**During installation, you'll be prompted for:**

1. **OpenAI API Key**: `sk-proj-your-key-here`
2. **OpenAI Prompt ID**: `pmpt_69158f49c30081978fefc0f93776ebfc078073f3992b13f0` (from step 3.1)
3. **Keep API URL**: `https://api.keephq-xxx.consultic.tech/alerts/event`
4. **Keep API Key**: `your-keep-api-key`
5. **ClickHouse Host**: `localhost` (if port 9000 exposed) or container IP
6. **ClickHouse Port**: `9000`
7. **Analysis Interval**: `10` (minutes)

**Installation will:**
- ✅ Install Python dependencies
- ✅ Create `/opt/log-analyzer/` directory
- ✅ Set up systemd service and timer
- ✅ Test ClickHouse connection
- ✅ Run initial analysis
- ✅ Schedule automatic runs every 10 minutes

### 2.3 Verify Installation

```bash
# Check service status
sudo systemctl status log-analyzer.timer
sudo systemctl status log-analyzer.service

# View logs
sudo journalctl -u log-analyzer.service -f

# Check next scheduled run
systemctl list-timers log-analyzer.timer
```

**Expected output:**
```
[INFO] Sending 12000 characters to OpenAI for analysis
[INFO] Using Responses API with platform prompt ID: pmpt_abc123...
[DEBUG] ======== OpenAI Request ========
[DEBUG]   prompt.id: pmpt_abc123...
[INFO] Received analysis from OpenAI Responses API
[SUCCESS] Alert sent to Keep: 202
```

### 2.4 Manual Test Run

```bash
# Trigger immediate analysis
sudo systemctl start log-analyzer.service

# Watch logs in real-time
sudo journalctl -u log-analyzer.service -f
```

---

## Verification

### Check Each Component

#### 1. SigNoz
```bash
# Check containers
docker ps | grep signoz

# Expected: clickhouse, query-service, otel-collector, frontend all running

# Access UI
curl -I http://localhost:3301
# Should return 200 OK
```

#### 2. ClickHouse Logs
```bash
# Check logs are being stored
docker exec signoz-clickhouse clickhouse-client --query \
  "SELECT count() FROM signoz_logs.logs_v2 WHERE timestamp > now() - interval 1 hour"

# Should return a number > 0
```

#### 3. AI Analyzer
```bash
# Check timer is active
sudo systemctl is-active log-analyzer.timer
# Should return: active

# View last analysis results
sudo cat /opt/log-analyzer/last_analysis.json | python3 -m json.tool

# Should show structured JSON with severity, issues, recommendations
```

#### 4. Keep Dashboard
- Open your Keep dashboard
- Look for alerts with source `ai-analyzer`
- Should see alerts with detailed analysis

### End-to-End Test

```bash
# Run full test
sudo systemctl start log-analyzer.service

# Check each stage
journalctl -u log-analyzer.service -n 100 | grep -E "\[INFO\]|\[SUCCESS\]"

# Expected output:
# [INFO] Retrieved 45 log entries
# [INFO] Sending 12000 characters to OpenAI
# [INFO] Received analysis from OpenAI
# [SUCCESS] Alert sent to Keep: 202
```

---

## Configuration Files

### `/opt/log-analyzer/.env`

```bash
# OpenAI Configuration
OPENAI_API_KEY=sk-proj-your-key
OPENAI_PROMPT_ID=pmpt_69158f49c30081978fefc0f93776ebfc078073f3992b13f0
OPENAI_PROMPT_VERSION=  # Optional: specific version

# Keep Configuration
KEEP_URL=https://api.keephq-xxx.consultic.tech/alerts/event
KEEP_API_KEY=your-keep-api-key

# ClickHouse Configuration
CLICKHOUSE_HOST=localhost
CLICKHOUSE_PORT=9000
CLICKHOUSE_DATABASE=signoz_logs

# Analysis Configuration
ANALYSIS_INTERVAL_MINUTES=10
```

### `/etc/systemd/system/log-analyzer.timer`

```ini
[Unit]
Description=AI Log Analyzer Timer - Run every 10 minutes
After=network.target

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
```

---

## Troubleshooting

### Common Issues

#### Issue: ClickHouse Connection Failed

```bash
# Check ClickHouse is running
docker ps | grep clickhouse

# Test connection
docker exec signoz-clickhouse clickhouse-client --query "SELECT 1"

# Check port is exposed
netstat -tlnp | grep 9000

# If not exposed, edit docker-compose.yaml and add port mapping
```

**Fix:**
```bash
cd ~/signoz/deploy
nano docker-compose.yaml
# Add under clickhouse service:
#   ports:
#     - "9000:9000"

docker-compose restart clickhouse
```

#### Issue: OpenAI Analysis Failing

```bash
# Check logs
sudo journalctl -u log-analyzer.service -n 50

# Common errors:
# "Invalid prompt ID" → Verify prompt ID in OpenAI dashboard
# "API key invalid" → Check OPENAI_API_KEY in .env
# "Input must contain 'json'" → Already fixed in deployment script
```

**Fix:**
```bash
# Verify configuration
sudo cat /opt/log-analyzer/.env

# Test OpenAI API key
curl https://api.openai.com/v1/models \
  -H "Authorization: Bearer $(grep OPENAI_API_KEY /opt/log-analyzer/.env | cut -d= -f2)"
```

#### Issue: Keep Not Receiving Alerts

```bash
# Test Keep endpoint
curl -X POST "$(grep KEEP_URL /opt/log-analyzer/.env | cut -d= -f2)" \
  -H "X-API-KEY: $(grep KEEP_API_KEY /opt/log-analyzer/.env | cut -d= -f2)" \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","status":"firing","severity":"info","message":"Test alert"}'

# Should return 2xx status code
```

#### Issue: Timer Not Running

```bash
# Check timer status
sudo systemctl status log-analyzer.timer

# Restart timer
sudo systemctl daemon-reload
sudo systemctl restart log-analyzer.timer
sudo systemctl enable log-analyzer.timer

# View schedule
systemctl list-timers log-analyzer.timer
```

#### Issue: Logs Truncated

Already fixed in the deployment script - logs are limited to:
- 2000 characters per log body
- 120,000 total characters per analysis
- Truncation notice added if logs exceed limits

### Debug Commands

```bash
# Full diagnostic output
sudo journalctl -u log-analyzer.service -n 200 --no-pager > /tmp/analyzer-debug.log

# Check formatted logs sent to OpenAI
sudo cat /opt/log-analyzer/last_analysis.txt

# Check AI response
sudo cat /opt/log-analyzer/last_analysis.json

# Check configuration
sudo cat /opt/log-analyzer/.env

# Run analyzer directly (for debugging)
cd /opt/log-analyzer
source venv/bin/activate
python3 analyzer.py
```

---

## Maintenance

### Update Analyzer

```bash
# Copy updated deployment script
scp deploy-log-analyzer.sh root@your-server:/tmp/

# SSH and re-run deployment (it will preserve your .env)
ssh root@your-server
sudo bash /tmp/deploy-log-analyzer.sh
# When prompted, choose to keep existing .env configuration
# The script will update the analyzer code automatically
```

### Update Configuration

```bash
# Edit config
sudo nano /opt/log-analyzer/.env

# Restart service
sudo systemctl restart log-analyzer.service
```

### Change Analysis Interval

```bash
# Option 1: Edit .env
sudo nano /opt/log-analyzer/.env
# Change: ANALYSIS_INTERVAL_MINUTES=15

# Option 2: Edit timer
sudo systemctl edit --full log-analyzer.timer
# Change: OnUnitActiveSec=15min

# Apply changes
sudo systemctl daemon-reload
sudo systemctl restart log-analyzer.timer
```

### View Logs

```bash
# Real-time logs
sudo journalctl -u log-analyzer.service -f

# Last 100 lines
sudo journalctl -u log-analyzer.service -n 100

# Errors only
sudo journalctl -u log-analyzer.service -p err

# Since specific time
sudo journalctl -u log-analyzer.service --since "1 hour ago"
```

---

## Cost Estimation

### OpenAI Costs

With default settings (10-minute intervals, ~45 logs per run):

**Per Run:**
- Input: ~12,000 characters (~3,000 tokens)
- Output: ~500 tokens
- Cost: ~$0.02 per run

**Monthly:**
- Runs per day: 144 (every 10 minutes)
- Runs per month: ~4,320
- **Estimated cost: ~$86/month**

**To reduce costs:**
1. Increase interval to 30 minutes: ~$29/month
2. Use gpt-4o-mini: ~$8/month
3. Reduce log limit in ClickHouse query

---

## Security Notes

- API keys stored in `/opt/log-analyzer/.env` with `600` permissions (owner only)
- Service runs as root (required for systemd timer)
- Debug files in `/opt/log-analyzer/` (owner-only access)
- Logs are stored by OpenAI with `store=True` for platform visibility
- To disable storage, edit `/opt/log-analyzer/analyzer.py` and change `store=True` to `store=False`

---

## Files Reference

### Core Files (This Repository)

- **`deploy-log-analyzer.sh`** - Automated deployment script (contains all analyzer code)

### Created During Deployment

- `/opt/log-analyzer/analyzer.py` - Analyzer service
- `/opt/log-analyzer/.env` - Configuration
- `/opt/log-analyzer/venv/` - Python virtual environment
- `/opt/log-analyzer/last_analysis.txt` - Last formatted logs
- `/opt/log-analyzer/last_analysis.json` - Last AI analysis
- `/etc/systemd/system/log-analyzer.service` - Systemd service
- `/etc/systemd/system/log-analyzer.timer` - Systemd timer

---

## Next Steps

After successful deployment:

1. **Monitor the first few runs** to ensure everything works
2. **Adjust OpenAI prompt** on the platform if needed (no code changes required)
3. **Set up Keep workflows** to act on critical alerts
4. **Fine-tune analysis interval** based on log volume and costs
5. **Create dashboards** in SigNoz for log visualization

---

## Support & Resources

### Documentation
- [SigNoz Docs](https://signoz.io/docs/)
- [OpenAI API Docs](https://platform.openai.com/docs)
- [Keep Docs](https://docs.keephq.dev/)

### Troubleshooting Guides (This Repo)
- `CLICKHOUSE_CONNECTION_GUIDE.md` - ClickHouse connectivity issues
- `OPENAI_RESPONSES_API_GUIDE.md` - OpenAI Responses API details
- `TEST_LOG_ANALYZER_FLOW.md` - Complete testing guide

### Quick Commands

```bash
# Status check
sudo systemctl status log-analyzer.timer
sudo journalctl -u log-analyzer.service -n 20

# Manual run
sudo systemctl start log-analyzer.service

# View results
cat /opt/log-analyzer/last_analysis.json | python3 -m json.tool

# Restart everything
sudo systemctl daemon-reload
sudo systemctl restart log-analyzer.timer
```

---

## Summary

You now have a complete observability stack with:
- ✅ SigNoz collecting and storing logs
- ✅ AI analyzing logs every 10 minutes
- ✅ OpenAI platform managing prompts and analysis
- ✅ Keep receiving alerts with recommendations
- ✅ Automated anomaly detection
- ✅ Full visibility in OpenAI platform

**Total Setup Time:** ~30-45 minutes
**Monthly Cost:** ~$86 (OpenAI) + Keep subscription
**Maintenance:** Minimal - review and adjust prompts as needed

---

**Version:** 1.0  
**Last Updated:** November 14, 2025  
**Status:** Production Ready ✅

