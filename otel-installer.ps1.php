<?php
// Return plain text so browser shows script
header("Content-Type: text/plain; charset=utf-8");
header("Content-Disposition: inline; filename=\"otel-installer.ps1\"");

// ---------------------------
// Read GET params (no ?? operator)
// ---------------------------
$label = isset($_GET['label']) ? $_GET['label'] : "9f3n626v2r.consultic.eu";
$otlp  = isset($_GET['otlp'])  ? $_GET['otlp']  : "http://signoz-q5vp.consultic.eu:4318";
$tag   = isset($_GET['tag'])   ? $_GET['tag']   : "ONEAPP-IOR-POD0 / APPS / HORUS / SQL";

// ---------------------------
// Trim tag: keep only after FIRST "/"
// "CONSULTIC.EU / WORKSPACE-1 / CUST113" -> "WORKSPACE-1 / CUST113"
// ---------------------------
$pos = strpos($tag, '/');
if ($pos !== false) {
    $tag = trim(substr($tag, $pos + 1));
}

// ---------------------------
// Escape for insertion into PowerShell strings
// ---------------------------
$label_esc = str_replace('"', '\"', $label);
$otlp_esc  = str_replace('"', '\"', $otlp);
$tag_esc   = str_replace('"', '\"', $tag);

// ---------------------------
// Dynamic param() block
// ---------------------------
echo "param(\n";
echo "    [string]\$Label = \"{$label_esc}\",\n";
echo "    [string]\$OtlpEndpoint = \"{$otlp_esc}\",\n";
echo "    [string]\$Tag = \"{$tag_esc}\"\n";
echo ")\n\n";

// ---------------------------
// Rest of PowerShell script (static, untouched)
// Use NOWDOC so PHP does not interpret anything
// ---------------------------
$ps = <<<'PS1'
# -------------------------------------------------------------
# 0. Ensure we are running as Administrator
# -------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Please run this PowerShell session as Administrator." -ForegroundColor Red
    return
}

# -------------------------------------------------------------
# 1. Variables
# -------------------------------------------------------------
$ServiceName   = "OTelCollector"
$InstallDir    = "C:\Program Files\otel-collector"
$OldInstallDir = "C:\otel-collector"
$StorageRoot   = "C:\ProgramData\otelcol"

$OtelVersion = "0.139.0"
$ArchiveName = "otelcol-contrib_${OtelVersion}_windows_amd64.tar.gz"
$DownloadUrl = "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OtelVersion/$ArchiveName"

Write-Host "=== Step 1: Stop & delete existing service (if any) ==="

# Be sure we are not "inside" the install directory while deleting it
Set-Location $env:TEMP

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Stopping existing service '$ServiceName'..."
    try {
        if ($existingService.Status -ne 'Stopped' -and $existingService.Status -ne 'StopPending') {
            Stop-Service -Name $ServiceName -Force
        }
    } catch {
        Write-Host "Warning: could not stop service cleanly: $($_.Exception.Message)"
    }

    Write-Host "Deleting service '$ServiceName' via sc.exe..."
    sc.exe delete $ServiceName
    Start-Sleep 2
} else {
    Write-Host "Service '$ServiceName' not found. OK."
}

# -------------------------------------------------------------
# 2. Remove old folders
# -------------------------------------------------------------
Write-Host "`n=== Step 2: Remove old folders ==="

foreach ($dir in @($OldInstallDir, $InstallDir, $StorageRoot)) {
    if (Test-Path $dir) {
        Write-Host "Removing '$dir'..."
        try {
            Remove-Item -Path $dir -Recurse -Force
        } catch {
            Write-Host "ERROR removing '$dir': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# -------------------------------------------------------------
# 3. Create install folder, download & extract collector
# -------------------------------------------------------------
Write-Host "`n=== Step 3: Create install folder, download & extract collector ==="

Write-Host "Creating '$InstallDir'..."
New-Item -ItemType Directory -Path $InstallDir -Force

Set-Location $InstallDir

Write-Host "Downloading OpenTelemetry Collector $OtelVersion..."
$archivePath = Join-Path $InstallDir $ArchiveName
Start-BitsTransfer -Source $DownloadUrl -Destination $archivePath

Write-Host "Extracting $ArchiveName..."
tar -xzf ".\$ArchiveName"

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: tar extraction failed with exit code $LASTEXITCODE" -ForegroundColor Red
    return
}

# -------------------------------------------------------------
# 4. Build tag and host.name attribute blocks
# -------------------------------------------------------------
Write-Host "`n=== Step 4: Build tag and host.name attribute blocks ==="

# Get hostname
$hostName = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($hostName)) {
    $hostName = [System.Net.Dns]::GetHostName()
}
Write-Host "Hostname detected: $hostName"

# Build host.name attribute
$hostNameYamlBlock = @"
      - key: host.name
        action: upsert
        value: "$hostName"
"@

# Build tags attribute (if provided)
$tagsYamlBlock = ""
$safeTag = $Tag.Trim()
if (-not [string]::IsNullOrWhiteSpace($safeTag)) {
    $escapedTag = ($safeTag -replace '"', '\"')
    $tagsYamlBlock = @"
      - key: tags
        action: upsert
        value: "$escapedTag"
"@
    Write-Host "Tag set to '$safeTag'"
} else {
    Write-Host "No tag provided. Skipping tag block."
}

# -------------------------------------------------------------
# 5. Write config.yaml (with safe single-quoted Windows paths)
# -------------------------------------------------------------
Write-Host "`n=== Step 5: Write config.yaml ==="

$configPath = Join-Path $InstallDir "config.yaml"

@"
# =========================
# OpenTelemetry Collector (Windows) -> SigNoz
# - Adds label + dynamic tags
# - Filters out INFO/DEBUG/TRACE and low-level Windows events
# =========================
extensions:
  file_storage:
    directory: 'C:\ProgramData\otelcol\storage'
    create_directory: true

receivers:
  # --- WINDOWS EVENT LOGS ---
  windowseventlog/application:
    channel: Application
    storage: file_storage
    start_at: end
  windowseventlog/system:
    channel: System
    storage: file_storage
    start_at: end
  windowseventlog/security:
    channel: Security
    storage: file_storage
    start_at: end

  # --- METRICS ---
  hostmetrics:
    collection_interval: 60s
    scrapers:
      cpu: {}
      memory: {}
      disk: {}
      filesystem: {}
      network: {}
      paging: {}

processors:
  # Add label, host.name and optional tags
  resource/add_label:
    attributes:
      - key: label
        action: upsert
        value: "$Label"
$hostNameYamlBlock
$tagsYamlBlock
  # Filter out INFO and below using multiple methods

  # Method 1: Filter by severity_number (if set)
  # Keep only WARN (13-16), ERROR (17-20), FATAL (21-24)
  # Filter out TRACE (1-4), DEBUG (5-8), INFO (9-12)
  filter/no_info_severity:
    error_mode: ignore
    logs:
      log_record:
        - 'severity_number < 13'

  # Method 2: Filter by severity_text (Windows Event Log often uses this)
  # Filter out INFO, DEBUG, TRACE level messages
  filter/no_info_text:
    error_mode: ignore
    logs:
      log_record:
        - 'severity_text == "INFO"'
        - 'severity_text == "Info"'
        - 'severity_text == "info"'
        - 'severity_text == "DEBUG"'
        - 'severity_text == "Debug"'
        - 'severity_text == "debug"'
        - 'severity_text == "TRACE"'
        - 'severity_text == "Trace"'
        - 'severity_text == "trace"'

  # Method 3: Filter by Windows Event Level (if present in attributes)
  # Windows levels: 1=Critical, 2=Error, 3=Warning, 4=Information, 5=Verbose
  filter/no_info_eventlevel:
    error_mode: ignore
    logs:
      log_record:
        - 'attributes["event.level"] == 4'  # Information
        - 'attributes["event.level"] == 5'  # Verbose
        - 'attributes["level"] == 4'
        - 'attributes["level"] == 5'


  resourcedetection:
    detectors: [system]
    override: false

  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  # SigNoz OTLP/HTTP
  otlphttp:
    endpoint: "$OtlpEndpoint"

service:
  extensions: [file_storage]

  telemetry:
    logs:
      level: info        # change to 'debug' to troubleshoot
      encoding: json
      output_paths:
        - '$InstallDir\collector.log'
        - 'stderr'

  pipelines:
    logs:
      receivers:
        - windowseventlog/application
        - windowseventlog/system
        - windowseventlog/security
      processors:
        - resourcedetection
        - resource/add_label
        - filter/no_info_severity
        - filter/no_info_text
        - filter/no_info_eventlevel
        - batch
      exporters:
        - otlphttp

    metrics:
      receivers:
        - hostmetrics
      processors:
        - resourcedetection
        - resource/add_label
        - batch
      exporters:
        - otlphttp

"@ | Set-Content -Path $configPath -Encoding UTF8

Write-Host "✅ config.yaml written at $configPath"

# -------------------------------------------------------------
# 6. Create service via New-Service
# -------------------------------------------------------------
Write-Host "`n=== Step 6: Create Windows service via New-Service ==="

$svcExe = Join-Path $InstallDir "otelcol-contrib.exe"
if (-not (Test-Path $svcExe)) {
    Write-Host "ERROR: Collector exe not found at $svcExe" -ForegroundColor Red
    return
}

$binaryPath = "`"$svcExe`" --config `"$configPath`""
Write-Host "BinaryPathName that will be registered:"
Write-Host $binaryPath

# Safety: if service somehow still exists, delete again
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Service '$ServiceName' still exists, deleting again via sc.exe..."
    sc.exe delete $ServiceName
    Start-Sleep 2
}

try {
    New-Service `
        -Name $ServiceName `
        -BinaryPathName $binaryPath `
        -DisplayName "OpenTelemetry Collector (SigNoz)" `
        -Description "OpenTelemetry Collector sending Windows logs/metrics to SigNoz" `
        -StartupType Automatic

    Write-Host "✅ Service '$ServiceName' created via New-Service."
} catch {
    Write-Host "ERROR: Failed to create service '$ServiceName': $($_.Exception.Message)" -ForegroundColor Red
    return
}

# -------------------------------------------------------------
# 7. Configure failure actions (sc, now that service exists)
# -------------------------------------------------------------
Write-Host "`n=== Step 7: Configure failure actions ==="
sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000

# -------------------------------------------------------------
# 8. Start service and verify
# -------------------------------------------------------------
Write-Host "`n=== Step 8: Start service and verify ==="

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
    Write-Host "✅ Service '$ServiceName' started."
} catch {
    Write-Host "ERROR: Failed to start service '$ServiceName': $($_.Exception.Message)" -ForegroundColor Red
}

Start-Sleep 3
Get-Service -Name $ServiceName

# -------------------------------------------------------------
# 9. Generate test Critical event
# -------------------------------------------------------------
Write-Host "`n=== Step 9: Generate test Critical event ==="
New-EventLog -LogName Application -Source "TestCriticalSource" -ErrorAction SilentlyContinue
Write-EventLog -LogName Application -Source "TestCriticalSource" -EventId 1001 -EntryType Error -Message "Test CRITICAL event for SigNoz integration check." -Category 1

Write-Host "`n✅ DONE"
Write-Host "   InstallDir  = $InstallDir"
Write-Host "   Label       = $Label"
Write-Host "   Tag         = $Tag"
Write-Host "   OTLP        = $OtlpEndpoint"
Write-Host "   Service     = $ServiceName"
Write-Host "   Logs file   = $InstallDir\collector.log"
PS1;

echo $ps;
