# ============================================================================
# PCModBridge GUI v1.0
# Pulls jobs from the GitHub queue and shows them in a window.
# You press [Run] to execute, [Skip] to drop, [Abort] to kill a running job.
# Token: C:\Users\s\PCModBridge\server\gh_poll_token.txt
# State: C:\Users\s\PCModBridge\state\last_processed.json
# Log:   C:\Users\s\PCModBridge\logs\gui_poller.log
# PowerShell 5.1 compatible. No dependencies.
# ============================================================================
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$script:Root     = 'C:\Users\s\PCModBridge'
$script:TokFile  = "$script:Root\server\gh_poll_token.txt"
$script:StateFile = "$script:Root\state\last_processed.json"
$script:LogFile  = "$script:Root\logs\gui_poller.log"
$script:Repo     = 'graciozee-create/pcmb-auto'
$script:BaseApi  = 'https://api.github.com/repos/graciozee-create/pcmb-auto'
$script:Branch   = 'main'
$script:PollMs   = 8000
$script:JobTimeoutSec = 240
$script:running  = $false
$script:proc     = $null
$script:jobs     = @{}
$script:state    = $null
$script:mutex    = $null

# ---------------- single instance ----------------
$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($false, 'PCModBridgeGuiMutex', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('GUI poller is already running (window is open somewhere).', 'PCModBridge')
    exit 0
}

function Log($m) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m
    try {
        $d = Split-Path $script:LogFile
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $script:LogFile -Value $line
    } catch {}
    if ($script:output -ne $null) {
        try { $script:output.AppendText($line + "`r`n") } catch {}
    }
}

function InvokeOnUI($sb) {
    if ($script:form -ne $null -and $script:form.InvokeRequired) { [void]$script:form.Invoke($sb) } else { . $sb }
}

# ---------------- GitHub API ----------------
function Gh($method, $path, $body) {
    $headers = @{ 'Authorization' = 'token ' + $script:token; 'Accept' = 'application/vnd.github+json' }
    $bodyStr = $null
    if ($body -ne $null) {
        $headers['Content-Type'] = 'application/json'
        $bodyStr = ($body | ConvertTo-Json -Compress -Depth 5)
    }
    try {
        $r = Invoke-RestMethod -Method $method -Uri ($script:BaseApi + $path) -Headers $headers -Body $bodyStr -TimeoutSec 30
        return @{ code = 200; value = $r }
    } catch {
        $code = -1
        $msg  = $_.Exception.Message
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            try {
                $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $bt = $sr.ReadToEnd()
                try { $msg = (($bt | ConvertFrom-Json).message) } catch { $msg = $bt }
            } catch {}
        }
        return @{ code = $code; value = $msg }
    }
}

function FetchQueue {
    $r = Gh 'GET' '/contents/poll_next.json' $null
    if ($r.code -ne 200) { return $null }
    $job = $null
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($r.value.content))
        $job  = ($json | ConvertFrom-Json)
    } catch { Log ('parse poll_next.json FAILED: ' + $_.Exception.Message) }
    return @{ sha = $r.value.sha; job = $job }
}

function LoadState {
    try {
        if (Test-Path $script:StateFile) {
            $raw = Get-Content $script:StateFile -Raw -EA SilentlyContinue
            if ($raw) { return ($raw | ConvertFrom-Json) }
        }
    } catch {}
    return $null
}

function SaveState($sha, $jobId) {
    try {
        $d = Split-Path $script:StateFile
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        (@{ sha = $sha; job_id = $jobId } | ConvertTo-Json) | Set-Content -Path $script:StateFile -Encoding UTF8
    } catch { Log ('state save failed: ' + $_.Exception.Message) }
}

# ---------------- token (ask if missing) ----------------
$token = ''
if (Test-Path $script:TokFile) { $token = (Get-Content $script:TokFile -Raw -EA SilentlyContinue).Trim() }
if (-not $token) {
    $pf = New-Object Windows.Forms.Form
    $pf.Text = 'PCModBridge: token'
    $pf.Size = New-Object Drawing.Size(580, 180)
    $pf.StartPosition = 'CenterScreen'
    $pf.FormBorderStyle = 'FixedDialog'
    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = 'Token file is missing. Paste the GitHub token and press OK:'
    $lbl.Location = New-Object Drawing.Point(12, 12)
    $lbl.AutoSize = $true
    $tb = New-Object Windows.Forms.TextBox
    $tb.Location = New-Object Drawing.Point(12, 44)
    $tb.Size = New-Object Drawing.Size(548, 26)
    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Location = New-Object Drawing.Point(12, 84)
    $ok.Size = New-Object Drawing.Size(90, 30)
    $cl = New-Object Windows.Forms.Button
    $cl.Text = 'Exit'
    $cl.Location = New-Object Drawing.Point(110, 84)
    $cl.Size = New-Object Drawing.Size(90, 30)
    $script:tokOk = $false
    $script:tokVal = ''
    $ok.Add_Click({ $script:tokVal = $tb.Text.Trim(); $script:tokOk = $true; $pf.Close() })
    $cl.Add_Click({ $pf.Close() })
    $pf.Controls.Add($lbl); $pf.Controls.Add($tb); $pf.Controls.Add($ok); $pf.Controls.Add($cl)
    [void]$pf.ShowDialog()
    if ($script:tokOk) {
        $token = $script:tokVal
        $d = Split-Path $script:TokFile
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Set-Content -Path $script:TokFile -Value $token -NoNewline
    } else { exit 0 }
}
$script:token = $token

# ---------------- main form ----------------
$form = New-Object Windows.Forms.Form
$script:form = $form
$form.Text = 'PCModBridge - job queue'
$form.Size = New-Object Drawing.Size(1010, 710)
$form.StartPosition = 'CenterScreen'

$status = New-Object Windows.Forms.Label
$script:status = $status
$status.Text = 'Initializing...'
$status.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$status.AutoSize = $true
$status.Location = New-Object Drawing.Point(12, 10)
$status.ForeColor = [Drawing.Color]::FromArgb(120, 120, 120)

$lastPoll = New-Object Windows.Forms.Label
$script:lastPoll = $lastPoll
$lastPoll.Text = ''
$lastPoll.Location = New-Object Drawing.Point(770, 15)
$lastPoll.AutoSize = $true

$qGroup = New-Object Windows.Forms.GroupBox
$qGroup.Text = 'Queue (jobs received from the server)'
$qGroup.Location = New-Object Drawing.Point(12, 40)
$qGroup.Size = New-Object Drawing.Size(978, 232)

$list = New-Object Windows.Forms.ListView
$script:list = $list
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
$list.MultiSelect = $false
$list.Location = New-Object Drawing.Point(10, 24)
$list.Size = New-Object Drawing.Size(958, 196)
[void]$list.Columns.Add('ID', 220)
[void]$list.Columns.Add('Received', 160)
[void]$list.Columns.Add('Status', 570)
$qGroup.Controls.Add($list)
$form.Controls.Add($qGroup)

$btnRun = New-Object Windows.Forms.Button
$script:btnRun = $btnRun
$btnRun.Text = 'Run job'
$btnRun.Location = New-Object Drawing.Point(12, 284)
$btnRun.Size = New-Object Drawing.Size(170, 38)
$btnRun.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$btnRun.BackColor = [Drawing.Color]::FromArgb(226, 245, 226)

$btnAbort = New-Object Windows.Forms.Button
$script:btnAbort = $btnAbort
$btnAbort.Text = 'Abort'
$btnAbort.Location = New-Object Drawing.Point(192, 284)
$btnAbort.Size = New-Object Drawing.Size(120, 38)
$btnAbort.Enabled = $false
$btnAbort.BackColor = [Drawing.Color]::FromArgb(252, 232, 232)

$btnSkip = New-Object Windows.Forms.Button
$script:btnSkip = $btnSkip
$btnSkip.Text = 'Skip job'
$btnSkip.Location = New-Object Drawing.Point(322, 284)
$btnSkip.Size = New-Object Drawing.Size(120, 38)

$cmdGroup = New-Object Windows.Forms.GroupBox
$cmdGroup.Text = 'Job command (preview)'
$cmdGroup.Location = New-Object Drawing.Point(12, 334)
$cmdGroup.Size = New-Object Drawing.Size(978, 112)
$cmdPreview = New-Object Windows.Forms.TextBox
$script:cmdPreview = $cmdPreview
$cmdPreview.Multiline = $true
$cmdPreview.ReadOnly = $true
$cmdPreview.ScrollBars = 'Vertical'
$cmdPreview.Font = New-Object Drawing.Font('Consolas', 8.5)
$cmdPreview.Location = New-Object Drawing.Point(10, 24)
$cmdPreview.Size = New-Object Drawing.Size(958, 78)
$cmdGroup.Controls.Add($cmdPreview)
$form.Controls.Add($cmdGroup)

$outGroup = New-Object Windows.Forms.GroupBox
$outGroup.Text = 'Output / log'
$outGroup.Location = New-Object Drawing.Point(12, 458)
$outGroup.Size = New-Object Drawing.Size(978, 238)
$output = New-Object Windows.Forms.TextBox
$script:output = $output
$output.Multiline = $true
$output.ReadOnly = $true
$output.ScrollBars = 'Both'
$output.WordWrap = $false
$output.Font = New-Object Drawing.Font('Consolas', 8.5)
$output.Location = New-Object Drawing.Point(10, 24)
$output.Size = New-Object Drawing.Size(958, 204)
$outGroup.Controls.Add($output)
$form.Controls.Add($outGroup)

$chkAuto = New-Object Windows.Forms.CheckBox
$script:chkAuto = $chkAuto
$chkAuto.Text = 'Auto-run jobs (recommended)'
$chkAuto.Checked = $true
$chkAuto.AutoSize = $true
$chkAuto.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$chkAuto.Location = New-Object Drawing.Point(826, 10)

$form.Controls.Add($status)
$form.Controls.Add($lastPoll)
$form.Controls.Add($btnRun)
$form.Controls.Add($btnAbort)
$form.Controls.Add($btnSkip)
$form.Controls.Add($chkAuto)

function SetStatus($color, $text) {
    InvokeOnUI {
        $script:status.Text = $text
        if ($color -eq 'green')     { $script:status.ForeColor = [Drawing.Color]::FromArgb(0, 130, 0) }
        elseif ($color -eq 'red')   { $script:status.ForeColor = [Drawing.Color]::FromArgb(200, 0, 0) }
        elseif ($color -eq 'orange'){ $script:status.ForeColor = [Drawing.Color]::FromArgb(215, 130, 0) }
        else                        { $script:status.ForeColor = [Drawing.Color]::FromArgb(110, 110, 110) }
    }
}

function SelectedJobId {
    if ($script:list.SelectedItems.Count -gt 0) { return $script:list.SelectedItems[0].Text }
    return $null
}

function UpdateListStatus($id, $text) {
    InvokeOnUI {
        foreach ($it in $script:list.Items) {
            if ($it.Text -eq $id) { $it.SubItems[2].Text = $text; break }
        }
    }
}

# ---------------- run / finish ----------------
function FinishRun($exitCode, $out, $err) {
    $id  = $script:runInfo.job.id
    $sha = $script:runInfo.sha
    if ($out -eq $null) { $out = '' }
    if ($err -eq $null) { $err = '' }
    if ($out.Length -gt 65000) { $out = $out.Substring(0, 65000) + "`r`n...TRUNCATED..." }
    if ($err.Length -gt 20000) { $err = $err.Substring(0, 20000) + "`r`n...TRUNCATED..." }
    $dur = 0
    if ($script:procStart) { $dur = [int](((Get-Date) - $script:procStart).TotalMilliseconds) }
    $resJson = (@{ job_id = $id; exit_code = $exitCode; duration_ms = $dur; stdout = $out; stderr = $err } | ConvertTo-Json -Depth 5 -Compress)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($resJson))
    SetStatus('orange', 'Uploading result of ' + $id + ' ...')
    $payload = @{ message = 'result ' + $id; content = $b64; encoding = 'base64'; branch = $script:Branch }
    $r = Gh 'PUT' ('/contents/results/' + $id + '.txt') $payload
    if (($r.code -eq 422 -or $r.code -eq 409)) {
        $g = Gh 'GET' ('/contents/results/' + $id + '.txt') $null
        if ($g.code -eq 200 -and $g.value.sha) {
            $payload.sha = $g.value.sha
            $r = Gh 'PUT' ('/contents/results/' + $id + '.txt') $payload
        }
    }
    $script:jobs[$id].status = ('Done exit=' + $exitCode)
    UpdateListStatus $id ('Done exit=' + $exitCode)
    if ($r.code -eq 200 -or $r.code -eq 201) {
        Log ('JOB ' + $id + ' finished exit=' + $exitCode + ' in ' + $dur + ' ms, result uploaded (code ' + $r.code + ')')
        SetStatus('green', ('Job ' + $id.Substring(0, 8) + ' DONE (exit=' + $exitCode + '). Result uploaded.'))
    } else {
        Log ('JOB ' + $id + ' finished exit=' + $exitCode + ' but UPLOAD FAILED code=' + $r.code + ' ' + $r.value)
        SetStatus('red', ('Job finished (exit=' + $exitCode + '), but upload FAILED: ' + $r.code + '. Press Run on the same job to re-upload is impossible - contact agent.'))
    }
    SaveState $sha $id
    InvokeOnUI {
        $script:output.AppendText("=== JOB " + $id + " exit=" + $exitCode + " ===`r`n")
        $script:output.AppendText($out + "`r`n")
        if ($err) { $script:output.AppendText("STDERR: " + $err + "`r`n") }
        $script:output.AppendText("=== END JOB ===`r`n`r`n")
    }
    $script:proc = $null
    $script:runInfo = $null
    $script:running = $false
    InvokeOnUI {
        $script:btnRun.Enabled = $true
        $script:btnAbort.Enabled = $false
        $script:btnSkip.Enabled = $true
    }
}

function StartJob($id) {
    if ($script:running) { return }
    if (-not $id -or -not $script:jobs.ContainsKey($id)) { return }
    $info = $script:jobs[$id]
    if ($info.status -ne 'Pending') { return }
    $script:running = $true
    $script:runInfo = $info
    InvokeOnUI {
        $script:cmdPreview.Text = $info.job.cmd
        $script:btnRun.Enabled = $false
        $script:btnAbort.Enabled = $true
        $script:btnSkip.Enabled = $false
    }
    SetStatus('orange', ('Starting job ' + $id + ' ...'))
    Log ('RUN JOB ' + $id)
    try {
        $temp    = Join-Path $env:TEMP ('pcmb_job_' + $id + '.ps1')
        $outFile = Join-Path $env:TEMP ('pcmb_out_' + $id)
        $errFile = Join-Path $env:TEMP ('pcmb_err_' + $id)
        Remove-Item $outFile -EA SilentlyContinue
        Remove-Item $errFile -EA SilentlyContinue
        [IO.File]::WriteAllText($temp, $info.job.cmd, (New-Object Text.UTF8Encoding($false)))
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $temp) `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -WindowStyle Hidden -PassThru
        $script:proc = $proc
        $script:procStart = Get-Date
        $script:outFile = $outFile
        $script:errFile = $errFile
        $script:tempFile = $temp
        Log ('job process started pid=' + $proc.Id)
    } catch {
        Log ('START FAILED: ' + $_.Exception.Message)
        FinishRun -1 $null $null
    }
}

$btnRun.Add_Click({
    $id = SelectedJobId
    if (-not $id -or -not $script:jobs.ContainsKey($id)) {
        [System.Windows.Forms.MessageBox]::Show('Select a job in the list first.', 'PCModBridge')
        return
    }
    StartJob $id
})

$btnAbort.Add_Click({
    if ($script:proc -ne $null -and -not $script:proc.HasExited) {
        try { $script:proc.Kill($true) } catch { try { $script:proc.Kill() } catch {} }
        Log 'JOB aborted by user (killed)'
        SetStatus('orange', 'Aborting...')
    }
})

$btnSkip.Add_Click({
    $id = SelectedJobId
    if (-not $id -or -not $script:jobs.ContainsKey($id)) { return }
    $info = $script:jobs[$id]
    if ($info.status -ne 'Pending') { return }
    $script:jobs[$id].status = 'Skipped'
    UpdateListStatus $id 'Skipped'
    SaveState $info.sha $id
    Log ('JOB ' + $id + ' SKIPPED by user (sha ' + $info.sha + ')')
    SetStatus('green', ('Job ' + $id.Substring(0, 8) + ' skipped.'))
})

$list.Add_SelectedIndexChanged({
    if ($script:list.SelectedItems.Count -gt 0) {
        $id = $script:list.SelectedItems[0].Text
        if ($script:jobs.ContainsKey($id)) { $script:cmdPreview.Text = $script:jobs[$id].job.cmd }
    }
})

# ---------------- poll timer ----------------
$script:pollTimer = New-Object System.Timers.Timer $script:PollMs
$script:pollTimer.AutoReset = $true
$script:pollTimer.Add_Elapsed({
    try {
        if ($script:running) { return }
        $q = FetchQueue
        $ts = 'Last check: ' + (Get-Date -Format 'HH:mm:ss')
        InvokeOnUI { $script:lastPoll.Text = $ts }
        if ($q -eq $null) {
            SetStatus('red', 'Cannot reach GitHub (network problem or bad token). Retrying...')
            return
        }
        if ($q.job -eq $null) {
            SetStatus('green', 'Connected to GitHub. Queue is empty.')
            return
        }
        # already processed before (state file)
        if ($script:state -ne $null -and $script:state.job_id -eq $q.job.id -and $script:state.sha -eq $q.sha) {
            SetStatus('green', ('Connected. No new jobs (last processed: ' + $q.job.id.Substring(0, 8) + ').'))
            return
        }
        if (-not $script:jobs.ContainsKey($q.job.id)) {
            $script:jobs[$q.job.id] = @{
                sha = $q.sha; job = $q.job
                received = (Get-Date -Format 'HH:mm:ss'); status = 'Pending'
            }
            InvokeOnUI {
                $it = New-Object Windows.Forms.ListViewItem($q.job.id)
                $it.SubItems.Add($script:jobs[$q.job.id].received)
                $it.SubItems.Add('PENDING - press Run')
                $script:list.Items.Add($it)
            }
            [System.Media.SystemSounds]::Exclamation.Play()
            Log ('NEW JOB RECEIVED: ' + $q.job.id)
            $auto = $true
            InvokeOnUI { $auto = $script:chkAuto.Checked }
            if ($auto) {
                Log ('AUTO-RUN: starting job ' + $q.job.id)
                StartJob $q.job.id
            }
        }
        $hasPending = $false
        foreach ($k in $script:jobs.Keys) { if ($script:jobs[$k].status -eq 'Pending') { $hasPending = $true; break } }
        if ($hasPending -and -not $script:running) { SetStatus('orange', 'JOB IS WAITING - press the green button!') }
        elseif ($hasPending) { SetStatus('orange', 'AUTO: running...') }
        else { SetStatus('green', 'Connected. All jobs processed. Waiting for new ones...') }
    } catch {
        SetStatus('red', ('Error: ' + $_.Exception.Message))
    }
})
$script:pollTimer.Start()

# ---------------- job-watch timer (exit + timeout) ----------------
$script:checkTimer = New-Object System.Timers.Timer 500
$script:checkTimer.AutoReset = $true
$script:checkTimer.Add_Elapsed({
    if (-not $script:running -or $script:proc -eq $null -or $script:runInfo -eq $null) { return }
    $id = $script:runInfo.job.id
    $elapsed = 0
    if ($script:procStart) { $elapsed = [int](((Get-Date) - $script:procStart).TotalSeconds) }
    if (-not $script:proc.HasExited) {
        if ($elapsed -gt $script:JobTimeoutSec) {
            Log ('JOB ' + $id + ' TIMEOUT after ' + $elapsed + 's, killing')
            try { $script:proc.Kill($true) } catch { try { $script:proc.Kill() } catch {} }
        } else {
            SetStatus('orange', ('Running ' + $id.Substring(0, 8) + ' ... ' + $elapsed + 's / ' + $script:JobTimeoutSec + 's'))
        }
        return
    }
    # process exited
    $script:running = $false
    $exit = -1
    try { $exit = $script:proc.ExitCode } catch {}
    Start-Sleep -Milliseconds 400
    $out = ''; $err = ''
    try { $out = [IO.File]::ReadAllText($script:outFile) } catch {}
    try { $err = [IO.File]::ReadAllText($script:errFile) } catch {}
    foreach ($f in @($script:tempFile, $script:outFile, $script:errFile)) { Remove-Item $f -EA SilentlyContinue }
    FinishRun $exit $out $err
})
$script:checkTimer.Start()

# ---------------- close handling ----------------
$script:state = LoadState
$form.Add_FormClosed({
    try { $script:pollTimer.Stop() } catch {}
    try { $script:checkTimer.Stop() } catch {}
    try { $script:mutex.ReleaseMutex() } catch {}
})

Log ('GUI poller v1.0 started, pid=' + $PID)
[void][System.Windows.Forms.Application]::Run($form)
Log 'GUI poller closed'
exit 0
