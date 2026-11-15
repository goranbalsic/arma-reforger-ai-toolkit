param([switch]$Check)
# Arma Reforger batch download - local web dashboard.
# double-click the Desktop .cmd: serves http://localhost:8123 and opens your browser.
# buttons: Start/Resume, Pause, Verify mods (size-checks every assembled mod).
$ErrorActionPreference = 'Stop'
$W       = $PSScriptRoot
$Exe     = "$W\armar-server\ArmaReforgerServer.exe"
$Cfg     = "$env:USERPROFILE\Documents\Default Project\batch1-serverconfig.json"
$Sizes   = "$env:USERPROFILE\Documents\Default Project\batch1-sizes.json"
$Profile = "$W\serverprofile"
$Addons  = "$Profile\addons"
$Url     = 'http://localhost:8123/'

$j = Get-Content $Sizes -Raw | ConvertFrom-Json
$sizeMap = @{}
foreach ($p in $j.mods.PSObject.Properties) { $sizeMap[$p.Name] = $p.Value }
$TotalBytes = $j.totalBytes

$verify = $null   # last verify result shown on the page

function Get-DS { Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue }

function Get-Log {
  Get-ChildItem "$Profile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$script:dirCache = $null; $script:dirCacheAt = (Get-Date).AddMinutes(-10)

function Get-DirMap {
  # one recursive pass, grouped by folder - far faster than per-folder listings
  if (((Get-Date) - $script:dirCacheAt).TotalSeconds -lt 5) { return $script:dirCache }
  $map = @{}
  Get-ChildItem $Addons -Recurse -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      if ($_.Directory.Name -notmatch '_([0-9A-F]{16})$') { return }
      if ($_.Directory.Name -match '^RHS-ContentPack0[12]_') { return }
      $g = $Matches[1]
      $e = $map[$g]
      if (-not $e) {
        $e = $map[$g] = @{ name = $_.Directory.Name -replace '_[0-9A-F]{16}$', ''; bytes = [double]0
                           assembled = 0; mtime = $_.Directory.LastWriteTime }
      }
      $e.bytes += $_.Length
      if ($_.Name -in 'addon.gproj','meta','resourceDatabase.rdb') { $e.assembled++ }
    }
  foreach ($e in $map.Values) { $e.assembled = ($e.assembled -eq 3) }
  $script:dirCache = $map; $script:dirCacheAt = Get-Date
  $map
}

function Get-GlobalSpeed {
  $lg = Get-Log
  if (-not $lg) { return 0 }
  $line = Get-Content $lg.FullName -Tail 60 | Select-String 'Download speed ([0-9.]+) KB/s' | Select-Object -Last 1
  if ($line) { [Math]::Round($line.Matches[0].Groups[1].Value / 1024, 1) } else { 0 }
}

function Get-Status {
  $dirs = Get-DirMap
  $doneBytes = ($dirs.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum

  # complete = folder stable (no writes 2 min) AND assembled AND size matches Workshop (when known).
  # the DS writes gproj/meta/rdb before the data paks, so "assembled" alone lies mid-download.
  $now = Get-Date
  $completed = @{}
  foreach ($e in $dirs.GetEnumerator()) {
    $d = $e.Value
    if (-not $d.assembled -or $d.mtime -gt $now.AddMinutes(-2)) { continue }
    $sm = $sizeMap[$e.Key]; $exp = if ($sm) { [double]$sm.bytes } else { 0 }
    if ($exp -and [Math]::Abs($d.bytes - $exp) -gt [Math]::Max(2MB, 0.02 * $exp)) { continue }
    $completed[$e.Key] = $true
  }
  $doneCount = $completed.Count

  # active = folders still changing, newest first (up to 3)
  $active = @($dirs.GetEnumerator() |
    Where-Object { -not $completed.ContainsKey($_.Key) -and $_.Value.mtime -gt $now.AddMinutes(-5) } |
    Sort-Object { $_.Value.mtime } -Descending | Select-Object -First 3) | ForEach-Object {
    $sm = $sizeMap[$_.Key]; $exp = if ($sm) { [double]$sm.bytes } else { 0 }
    @{ name = $_.Value.name; mb = [Math]::Round($_.Value.bytes/1MB, 1); expMb = [Math]::Round($exp/1MB, 1);
       pct = if ($exp) { [Math]::Min(100, [int](100 * $_.Value.bytes / $exp)) } else { 0 } }
  }

  # recently completed (15 min), newest first
  $recent = @($dirs.GetEnumerator() | Where-Object { $completed.ContainsKey($_.Key) -and
    $_.Value.mtime -gt $now.AddMinutes(-15) } |
    Sort-Object { $_.Value.mtime } -Descending | Select-Object -First 12) | ForEach-Object {
    @{ name = $_.Value.name; gb = [Math]::Round($_.Value.bytes/1GB, 2); mb = [Math]::Round($_.Value.bytes/1MB, 1) }
  }

  @{ running = [bool](Get-DS); speed = Get-GlobalSpeed
     doneGb = [Math]::Round($doneBytes/1GB, 2); totalGb = [Math]::Round($TotalBytes/1GB, 2)
     pct = [Math]::Min(100, [int](100 * $doneBytes / $TotalBytes))
     doneCount = $doneCount; totalMods = $sizeMap.Count
     active = @($active); recent = @($recent); verify = $verify }
}

if ($Check) {
  try { Get-Status | ConvertTo-Json -Depth 5 | Out-String -Width 300 }
  catch { "GET-STATUS FAILED: $($_.Exception.Message)"; "at: $($_.InvocationInfo.PositionMessage)" }
  exit 0
}

function Start-DS {
  if (Get-DS) { return 'already running' }
  Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`" -profile `"$Profile`"" `
    -WorkingDirectory "$W\armar-server" -WindowStyle Hidden
  Start-Sleep 3
  if (Get-DS) { 'started' } else { 'FAILED to start - check server.log' }
}

function Stop-DS {
  $p = Get-DS
  if (-not $p) { return 'not running' }
  $p | Stop-Process -Force
  Start-Sleep 1
  'paused - progress kept'
}

function Invoke-Verify {
  # shortcut: verifies only the 561 batch mods against Workshop sizes; dependency
  # mods the DS auto-pulls are outside sizeMap and skipped - upgrade by adding
  # their ids to the sizes file if deps ever need checking
  $dirs = Get-DirMap
  $ok = 0; $partial = 0; $pending = 0; $suspects = @()
  foreach ($id in $sizeMap.Keys) {
    $sm = $sizeMap[$id]; $exp = [double]$sm.bytes
    $d = $dirs[$id]
    if (-not $d) { $pending++; continue }
    if (-not $d.assembled) { $partial++; continue }
    if ([Math]::Abs($d.bytes - $exp) -le [Math]::Max(2MB, 0.02 * $exp)) { $ok++ }
    else { $suspects += @{ name = $d.name; exp = [Math]::Round($exp/1GB, 2); act = [Math]::Round($d.bytes/1GB, 2) } }
  }
  $script:verify = @{ at = (Get-Date -f 'HH:mm:ss'); ok = $ok; partial = $partial
                      pending = $pending; suspects = $suspects }
  "verify: $ok ok, $partial partial, $pending pending, $($suspects.Count) suspects"
}

$html = @'
<!doctype html><html><head><meta charset="utf-8"><title>Reforger Mods Download</title>
<style>
 body{background:#17181c;color:#d6d8de;font-family:Segoe UI,Arial,sans-serif;margin:0;padding:24px}
 .card{background:#1f2127;border-radius:10px;padding:16px 20px;margin:0 auto 14px;max-width:760px}
 h1{font-size:18px;margin:0 0 12px;color:#fff}
 .dot{display:inline-block;width:10px;height:10px;border-radius:5px;margin-right:6px}
 .bar{background:#2a2d34;border-radius:6px;height:14px;overflow:hidden}
 .bar>div{height:14px;background:#4cc35e}
 .bar.amber>div{background:#e0b13e}
 .row{display:flex;justify-content:space-between;margin:6px 0 4px;font-size:13px}
 button{background:#3b6fe0;border:0;color:#fff;padding:9px 18px;border-radius:7px;font-size:14px;cursor:pointer;margin-right:8px}
 button.grey{background:#4a4e58} button.amber{background:#b3872e}
 button:disabled{opacity:.5;cursor:default}
 ul{list-style:none;margin:6px 0 0;padding:0;font-size:13px}
 li{padding:3px 0;border-bottom:1px solid #26282e}
 .ok{color:#7ed07e} .warn{color:#e0b13e} .bad{color:#e06c6c} .dim{color:#8a8e98}
 #vres{display:none}
 .big{font-size:26px;font-weight:600;color:#fff}
</style></head><body>
<div class="card"><h1>Arma Reforger Mods <span id="st"></span></h1>
 <div class="dim" id="boot">connecting to dashboard...</div>
 <div class="row"><span id="gbtxt" class="big"></span><span id="spd" class="dim"></span></div>
 <div class="bar"><div id="tbar" style="width:0%"></div></div>
 <div class="row"><span id="cnt" class="dim"></span><span class="dim" id="etabox"></span></div>
 <div style="margin-top:14px">
  <button id="bstart" onclick="act('start')">Start / Resume</button>
  <button id="bpause" class="grey" onclick="act('pause')">Pause</button>
  <button id="bverify" class="amber" onclick="act('verify')">Verify mods</button>
 </div>
 <div id="vres" class="card" style="margin:14px 0 0;padding:10px 14px"></div>
</div>
<div class="card" id="actcard" style="display:none"><h2 style="font-size:15px;margin:0 0 8px;color:#fff">Downloading now</h2><div id="act"></div></div>
<div class="card"><h2 style="font-size:15px;margin:0 0 4px;color:#fff">Completed (last 15 min)</h2><ul id="rec"></ul></div>
<script>
function fmt(n){return n.toFixed(2)}
async function tick(){
 try{
  const s=await (await fetch('/status')).json();
  const boot=document.getElementById('boot'); if(boot)boot.remove();
  document.getElementById('st').innerHTML=s.running
    ?'<span class="dot" style="background:#4cc35e"></span><span class="ok">running</span>'
    :'<span class="dot" style="background:#e06c6c"></span><span class="bad">stopped</span>';
  document.getElementById('gbtxt').textContent=fmt(s.doneGb)+' / '+fmt(s.totalGb)+' GB';
  document.getElementById('tbar').style.width=s.pct+'%';
  document.getElementById('spd').textContent=s.running?(s.speed+' MB/s'):'paused';
  document.getElementById('cnt').textContent=s.doneCount+' / '+s.totalMods+' mods assembled';
  const eta=(s.speed>0.05)?Math.round((s.totalGb-s.doneGb)*1024/s.speed/60)+' min left':'--';
  document.getElementById('etabox').textContent=eta;
  const ac=document.getElementById('actcard');
  if(s.active.length){ac.style.display='block';
   document.getElementById('act').innerHTML=s.active.map(a=>
    '<div class="row"><span>'+a.name+'</span><span class="dim">'+(a.expMb>0?(a.mb+' / '+a.expMb+' MB'):a.mb+' MB (dependency, size unknown)')+'</span></div>'+
    (a.expMb>0?'<div class="bar amber"><div style="width:'+a.pct+'%"></div></div>':'')).join('');
  } else ac.style.display='none';
  document.getElementById('rec').innerHTML=s.recent.length
    ?s.recent.map(r=>'<li class="ok">&#10003; '+r.name+' <span class="dim">'+(r.gb<0.1?fmt(r.mb)+' MB':fmt(r.gb)+' GB')+'</span></li>').join('')
    :'<li class="dim">nothing finished yet</li>';
  const v=document.getElementById('vres');
  if(s.verify){v.style.display='block';const x=s.verify;
   let t='<b>Verify '+x.at+'</b> - <span class="ok">'+x.ok+' ok</span>, '+x.partial+' partial, '+x.pending+' pending';
   if(x.suspects&&x.suspects.length){t+='<br><span class="bad">Size mismatch (re-download candidates):</span><ul>'+
     x.suspects.map(z=>'<li class="bad">'+z.name+' - expected '+z.exp+' GB, on disk '+z.act+' GB</li>').join('')+'</ul>';}
   else t+='<br><span class="ok">No size mismatches - installed mods look intact.</span>';
   v.innerHTML=t;}
 }catch(e){}
}
async function act(w){
 const b=event?event.target:null; if(b){b.disabled=true;b.textContent='...';}
 await fetch('/'+w,{method:'POST'}); if(w==='verify')await new Promise(r=>setTimeout(r,500));
 await tick(); if(b){b.disabled=false;b.textContent=w==='start'?'Start / Resume':w==='pause'?'Pause':'Verify mods';}
}
tick(); setInterval(tick,2000);
</script></body></html>
'@

$l = [System.Net.HttpListener]::new(); $l.Prefixes.Add($Url)
try { $l.Start() }
catch {
  # port busy -> a dashboard is already serving; just open it
  Write-Host 'dashboard already running - opening browser' -ForegroundColor Cyan
  Start-Process $Url
  exit 0
}
Write-Host '=== Arma Reforger Mods - web download dashboard ===' -ForegroundColor White
Write-Host "open: $Url   (keep this window open; closing it only stops the UI, not the download)" -ForegroundColor Cyan
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',`
  '-File',"$PSScriptRoot\sync-addons.ps1",'-Loop'   # auto-mirror completed mods into client addons
Start-Process $Url

while ($l.IsListening) {
  $ctx = $l.GetContext()
  try {
    $path = $ctx.Request.Url.AbsolutePath
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    switch ($path) {
      '/' {
        $b = [Text.Encoding]::UTF8.GetBytes($html)
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.ContentLength64 = $b.Length
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/status' {
        $b = [Text.Encoding]::UTF8.GetBytes((Get-Status | ConvertTo-Json -Depth 5 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/start'  { $msg = Start-DS;        Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/pause'  { $msg = Stop-DS;         Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/verify' { $msg = Invoke-Verify;   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      default   { $msg = $null; $ctx.Response.StatusCode = 404 }
    }
    if ($msg) {
      $b = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    }
  } catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $b = [Text.Encoding]::UTF8.GetBytes(('{"error":' + ($_.Exception.Message -replace '"',"'") + '}'))
    $ctx.Response.StatusCode = 500
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
  }
  finally { $ctx.Response.OutputStream.Close() }
}
