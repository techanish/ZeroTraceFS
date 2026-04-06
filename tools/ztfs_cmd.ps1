param(
  [Parameter(Mandatory = $true)]
  [string]$Action,

  [Parameter(Mandatory = $false)]
  [string]$TargetPath,

  [Parameter(Mandatory = $false)]
  [Nullable[Double]]$Minutes,

  [Parameter(Mandatory = $false)]
  [Nullable[Int]]$MaxReads,

  [Parameter(Mandatory = $false)]
  [string]$Deadline,

  [Parameter(Mandatory = $false)]
  [string]$Destination,

  [Parameter(Mandatory = $false)]
  [Nullable[Int]]$Recent,

  [Parameter(Mandatory = $false)]
  [switch]$Force,

  [Parameter(Mandatory = $false)]
  [switch]$SuppressResultDialog,

  [Parameter(Mandatory = $false)]
  [Nullable[Int]]$WaitSeconds,

  [Parameter(Mandatory = $false)]
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

function Resolve-ProjectRoot {
  param([string]$ProjectRoot)

  if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    return (Resolve-Path -LiteralPath $ProjectRoot).Path
  }

  $scriptDir = Split-Path -Parent $PSCommandPath
  return (Resolve-Path -LiteralPath (Join-Path $scriptDir "..")).Path
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function New-CommandFile {
  param(
    [string]$CommandsDir,
    [hashtable]$Payload
  )

  $stamp = Get-Date -Format "yyyyMMdd_HHmmssfff"
  $name = "cmd_${stamp}_$([Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
  $outFile = Join-Path $CommandsDir $name
  $Payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outFile -Encoding UTF8
  return $outFile
}

function Get-DialogInput {
  param(
    [string]$Title,
    [string]$Prompt,
    [string]$DefaultValue = ""
  )

  [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $DefaultValue)
}

function Confirm-Dialog {
  param(
    [string]$Title,
    [string]$Message
  )

  $result = [System.Windows.Forms.MessageBox]::Show(
    $Message,
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )
  $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function Select-DestinationFolder {
  param([string]$Description = "Select export destination folder")

  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = $Description
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    return $dlg.SelectedPath
  }
  return ""
}

function Get-PasswordDialog {
  param(
    [string]$Title = "ZeroTraceFS",
    [string]$Prompt = "Enter master password"
  )

  $form = New-Object System.Windows.Forms.Form
  $form.Text = $Title
  $form.Size = New-Object System.Drawing.Size(420, 170)
  $form.StartPosition = "CenterScreen"
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Prompt
  $label.AutoSize = $true
  $label.Location = New-Object System.Drawing.Point(15, 20)
  $form.Controls.Add($label)

  $textbox = New-Object System.Windows.Forms.TextBox
  $textbox.Location = New-Object System.Drawing.Point(18, 48)
  $textbox.Size = New-Object System.Drawing.Size(370, 25)
  $textbox.UseSystemPasswordChar = $true
  $form.Controls.Add($textbox)

  $okButton = New-Object System.Windows.Forms.Button
  $okButton.Text = "OK"
  $okButton.Location = New-Object System.Drawing.Point(226, 85)
  $okButton.Size = New-Object System.Drawing.Size(75, 28)
  $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.Controls.Add($okButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = "Cancel"
  $cancelButton.Location = New-Object System.Drawing.Point(313, 85)
  $cancelButton.Size = New-Object System.Drawing.Size(75, 28)
  $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $form.Controls.Add($cancelButton)

  $form.AcceptButton = $okButton
  $form.CancelButton = $cancelButton

  $result = $form.ShowDialog()
  if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    return $textbox.Text
  }
  return ""
}

function Show-ResultDialog {
  param(
    [string]$Title,
    [string]$Message,
    [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
  )

  [System.Windows.Forms.MessageBox]::Show(
    $Message,
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    $Icon
  ) | Out-Null
}

function Get-RuntimeHealth {
  param(
    [string]$Root,
    [int]$HealthyAgeSeconds = 35,
    [int]$WarningAgeSeconds = 300
  )

  $statusPath = Join-Path $Root ".zerotracefs\status.json"
  if (-not (Test-Path -LiteralPath $statusPath)) {
    return [pscustomobject]@{
      Healthy = $false
      AgeSeconds = $null
      Reason = "Missing .zerotracefs/status.json"
    }
  }

  try {
    $statusObj = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    $timestampRaw = [string]$statusObj.timestamp
    if ([string]::IsNullOrWhiteSpace($timestampRaw)) {
      return [pscustomobject]@{
        Healthy = $false
        AgeSeconds = $null
        Reason = "status.json has no timestamp"
      }
    }

    $statusUtc = (Get-Date -Date $timestampRaw).ToUniversalTime()
    $age = [Math]::Abs(((Get-Date).ToUniversalTime() - $statusUtc).TotalSeconds)
    if ($age -le $HealthyAgeSeconds) {
      return [pscustomobject]@{
        Healthy = $true
        AgeSeconds = $age
        Reason = ""
      }
    }

    if ($age -le $WarningAgeSeconds) {
      return [pscustomobject]@{
        Healthy = $false
        AgeSeconds = $age
        Reason = "Runtime heartbeat appears stale ($([Math]::Round($age, 1))s old)"
      }
    }

    return [pscustomobject]@{
      Healthy = $false
      AgeSeconds = $age
      Reason = "Runtime likely inactive ($([Math]::Round($age, 1))s old heartbeat)"
    }
  } catch {
    return [pscustomobject]@{
      Healthy = $false
      AgeSeconds = $null
      Reason = "Could not parse status.json"
    }
  }
}

function Wait-CommandResult {
  param(
    [string]$ProcessedDir,
    [string]$SourceFileName,
    [int]$TimeoutSeconds = 15
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $matches = Get-ChildItem -LiteralPath $ProcessedDir -Filter *.json -File -ErrorAction SilentlyContinue
    if ($null -ne $matches -and $matches.Count -gt 0) {
      foreach ($item in $matches) {
        try {
          $obj = Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json
          if ([string]$obj.source_file -eq $SourceFileName) {
            return $obj
          }
        } catch {
          continue
        }
      }
    }
    Start-Sleep -Milliseconds 100
  }

  return $null
}

function Format-ResultMessage {
  param([object]$ResultObj)

  if ($null -eq $ResultObj) {
    return "Command queued. Waiting for result timed out."
  }

  $message = [string]$ResultObj.message
  $actionName = ""
  if ($null -ne $ResultObj.payload -and $null -ne $ResultObj.payload.action) {
    $actionName = [string]$ResultObj.payload.action
  }

  if ($actionName -eq "read" -and $null -ne $ResultObj.data -and $null -ne $ResultObj.data.preview) {
    $preview = [string]$ResultObj.data.preview
    if ($preview.Length -gt 1600) {
      $preview = $preview.Substring(0, 1600) + "`r`n... [truncated]"
    }

    $previewType = [string]$ResultObj.data.preview_type
    $readCount = $ResultObj.data.read_count
    $ttlRemaining = $ResultObj.data.ttl_remaining_seconds
    $previewHeader = if ($previewType -eq "hex") { "Preview (hex):" } else { "Preview:" }

    $suffix = ""
    if ($null -ne $readCount) {
      $suffix += "`r`nRead count: $readCount"
    }
    if ($null -ne $ttlRemaining) {
      $suffix += "`r`nTTL remaining (sec): $([Math]::Round([double]$ttlRemaining, 1))"
    }

    return "$message$suffix`r`n`r`n$previewHeader`r`n$preview"
  }

  if (($actionName -eq "open-secure" -or $actionName -eq "export") -and $null -ne $ResultObj.data) {
    $suffix = ""
    if ($null -ne $ResultObj.data.read_count) {
      $suffix += "`r`nRead count: $($ResultObj.data.read_count)"
    }
    if ($null -ne $ResultObj.data.ttl_remaining_seconds) {
      $suffix += "`r`nTTL remaining (sec): $([Math]::Round([double]$ResultObj.data.ttl_remaining_seconds, 1))"
    }
    return "$message$suffix"
  }

  if ($actionName -eq "list" -and $null -ne $ResultObj.data -and $null -ne $ResultObj.data.count) {
    return "$message`r`nFiles in vault: $([int]$ResultObj.data.count)"
  }

  if ($actionName -eq "audit" -and $null -ne $ResultObj.data -and $null -ne $ResultObj.data.count) {
    return "$message`r`nAudit entries returned: $([int]$ResultObj.data.count)"
  }

  return $message
}

$root = Resolve-ProjectRoot -ProjectRoot $ProjectRoot
$controlDir = Join-Path $root ".zerotracefs"
$commandsDir = Join-Path $controlDir "commands"
 $processedDir = Join-Path $controlDir "processed"
Ensure-Directory -Path $commandsDir
Ensure-Directory -Path $processedDir

$runtime = Get-RuntimeHealth -Root $root
$runtimeWarning = $null
if (-not $runtime.Healthy) {
  $runtimeWarning = "ZeroTraceFS runtime may not be actively processing commands.`r`n$($runtime.Reason)"
}

$normalizedAction = $Action.Trim().ToLowerInvariant()
$payload = @{
  action = $normalizedAction
}

switch ($normalizedAction) {
  "status" {
  }
  "list" {
  }
  "audit" {
    if ($PSBoundParameters.ContainsKey("Recent") -and $null -ne $Recent) {
      if ([int]$Recent -lt 1) {
        throw "Recent must be at least 1."
      }
      $payload.recent = [int]$Recent
    }
  }
  "read" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "read requires a file path argument."
    }
    $payload.target = $TargetPath
  }
  "open-secure" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "open-secure requires a file path argument."
    }
    $password = Get-PasswordDialog -Title "ZeroTraceFS" -Prompt "Enter vault master password to open this file"
    if ([string]::IsNullOrWhiteSpace($password)) {
      throw "Cancelled by user."
    }
    $payload.target = $TargetPath
    $payload.password = $password
  }
  "export" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "export requires a file path argument."
    }
    $payload.target = $TargetPath
    $destinationValue = $Destination
    if ([string]::IsNullOrWhiteSpace($destinationValue)) {
      $destinationValue = Select-DestinationFolder -Description "Select export destination"
    }
    if (-not [string]::IsNullOrWhiteSpace($destinationValue)) {
      $payload.destination = $destinationValue
    }
  }
  "import" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "import requires a file path argument."
    }
    $payload.source = $TargetPath
  }
  "destroy" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "destroy requires a file path argument."
    }
    $payload.target = $TargetPath
  }
  "set-ttl" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "set-ttl requires a file path argument."
    }
    $minutesValue = 0.0
    if ($PSBoundParameters.ContainsKey("Minutes") -and $null -ne $Minutes) {
      $minutesValue = [double]$Minutes
    } else {
      $minutes = Get-DialogInput -Title "ZeroTraceFS" -Prompt "Enter TTL in minutes" -DefaultValue "10"
      if ([string]::IsNullOrWhiteSpace($minutes)) {
        throw "Cancelled by user."
      }
      if (-not [double]::TryParse($minutes, [ref]$minutesValue)) {
        throw "TTL must be numeric."
      }
    }
    if ($minutesValue -le 0) {
      throw "TTL must be greater than 0."
    }
    $payload.target = $TargetPath
    $payload.minutes = [double]$minutesValue
  }
  "set-reads" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "set-reads requires a file path argument."
    }
    $readsValue = 0
    if ($PSBoundParameters.ContainsKey("MaxReads") -and $null -ne $MaxReads) {
      $readsValue = [int]$MaxReads
    } else {
      $reads = Get-DialogInput -Title "ZeroTraceFS" -Prompt "Enter max reads" -DefaultValue "3"
      if ([string]::IsNullOrWhiteSpace($reads)) {
        throw "Cancelled by user."
      }
      if (-not [int]::TryParse($reads, [ref]$readsValue)) {
        throw "Max reads must be an integer."
      }
    }
    if ($readsValue -lt 1) {
      throw "Max reads must be at least 1."
    }
    $payload.target = $TargetPath
    $payload.max_reads = [int]$readsValue
  }
  "set-deadline" {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
      throw "set-deadline requires a file path argument."
    }
    $deadlineValue = $Deadline
    if ([string]::IsNullOrWhiteSpace($deadlineValue)) {
      $deadlineValue = Get-DialogInput -Title "ZeroTraceFS" -Prompt "Enter deadline (YYYY-MM-DD HH:MM:SS)" -DefaultValue "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }
    if ([string]::IsNullOrWhiteSpace($deadlineValue)) {
      throw "Deadline must not be empty."
    }
    $payload.target = $TargetPath
    $payload.deadline = $deadlineValue
  }
  "destroy-all" {
    if (-not $Force) {
      if (-not (Confirm-Dialog -Title "ZeroTraceFS" -Message "Destroy the entire vault? This cannot be undone.")) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
      }
    }
  }
  "lock" {
  }
  "quit" {
  }
  default {
    throw "Unsupported action: $Action"
  }
}

$created = New-CommandFile -CommandsDir $commandsDir -Payload $payload

$effectiveWait = 0
if ($PSBoundParameters.ContainsKey("WaitSeconds") -and $null -ne $WaitSeconds) {
  $effectiveWait = [Math]::Max(0, [int]$WaitSeconds)
} else {
  # Smart timeout defaults based on action type
  switch ($normalizedAction) {
    # Quick actions: 5 seconds
    { $_ -in @("status", "list") } { $effectiveWait = 5 }
    # Slow actions: 20 seconds
    { $_ -in @("import", "export", "open-secure", "destroy-all") } { $effectiveWait = 20 }
    # Medium actions: 10 seconds (default)
    default { $effectiveWait = 10 }
  }
}

if (-not $SuppressResultDialog -and $effectiveWait -gt 0) {
  $resultObj = Wait-CommandResult -ProcessedDir $processedDir -SourceFileName (Split-Path -Leaf $created) -TimeoutSeconds $effectiveWait
  if ($null -eq $resultObj) {
    $message = "Command queued, but no processed result arrived yet."
    if (-not [string]::IsNullOrWhiteSpace($runtimeWarning)) {
      $message = "$message`r`n`r`n$runtimeWarning`r`nStart source(""main.R"") and keep it running."
    }
    Show-ResultDialog -Title "ZeroTraceFS" -Message $message -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)
  } else {
    $dialogMessage = Format-ResultMessage -ResultObj $resultObj
    if (-not [string]::IsNullOrWhiteSpace($runtimeWarning)) {
      $dialogMessage = "$dialogMessage`r`n`r`nNote: $runtimeWarning"
    }
    $icon = if ([string]$resultObj.status -eq "ok") {
      [System.Windows.Forms.MessageBoxIcon]::Information
    } else {
      [System.Windows.Forms.MessageBoxIcon]::Error
    }
    Show-ResultDialog -Title "ZeroTraceFS: $($resultObj.status)" -Message $dialogMessage -Icon $icon
  }
}

Write-Host "Queued ZeroTraceFS command:" -ForegroundColor Green
Write-Host "  $created"
Write-Host "Ensure main.R is running in the ZeroTraceFS terminal."
