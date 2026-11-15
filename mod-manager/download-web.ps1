param([switch]$Check)
# Arma Reforger mod manager - local web dashboard: batch downloader, live server
# browser, per-server queue-first, launcher presets, client addon sync.
# double-click the .cmd: serves http://localhost:8123 and opens your browser.
#
# Paths: everything is relative to this folder, so the project folder is portable.
#   RFMM_HOME  where the big data lives (serverprofile\, airmar-server\, steamcmd\)
#   RFMM_DATA  where the json state lives (data\)   [both optional; default = here]
# On this machine they are set until migrate-here.ps1 moves the folders in here.
$ErrorActionPreference = 'Stop'
$Root    = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data    = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$Exe     = "$Root\armar-server\ArmaReforgerServer.exe"
$Cfg     = "$Data\batch1-serverconfig.json"
$Sizes   = "$Data\batch1-sizes.json"
$ServersPath = "$Data\batch1-servers.json"
$Profile = "$Root\serverprofile"
$Addons  = "$Profile\addons"
$Url     = 'http://localhost:8123/'

$j = Get-Content $Sizes -Raw | ConvertFrom-Json
$sizeMap = @{}
foreach ($p in $j.mods.PSObject.Properties) { $sizeMap[$p.Name] = $p.Value }
$TotalBytes = $j.totalBytes

$serverList = @()
if (Test-Path $ServersPath) {
  $serverList = @((Get-Content $ServersPath -Raw | ConvertFrom-Json).servers)
  foreach ($sv in $serverList) { foreach ($m in $sv.mods) {
    $sm = $sizeMap[$m.id]
    $m | Add-Member -NotePropertyName e -NotePropertyValue ([double]($(if ($sm) { $sm.bytes } else { 0 }))) -Force
  } }
}

$verify = $null   # last verify result shown on the page

$ApiBase = 'https://api.reforgermods.net/v2'
$ApiH = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$script:bCache = @{}; $script:bCacheAt = @{}   # /browse search cache
$script:dCache = @{}; $script:dCacheAt = @{}   # /browse-server detail cache

function Get-DS { Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue }

function Get-Log {
  Get-ChildItem "$Profile\logs" -Recurse -Filter console.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$script:dirCache = $null; $script:dirCacheAt = (Get-Date).AddMinutes(-10)
$script:clCache = @(); $script:clCacheAt = (Get-Date).AddMinutes(-10)

function Get-ClientIds {
  # mod ids present in the client addons folder (installed before/outside this batch)
  if (((Get-Date) - $script:clCacheAt).TotalSeconds -lt 5) { return $script:clCache }
  $ids = @(Get-ChildItem "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { if ($_.Name -match '_([0-9A-F]{16})$') { $Matches[1] } })
  $script:clCache = $ids; $script:clCacheAt = Get-Date
  $ids
}

function Get-DirMap {
  # one recursive pass, grouped by folder - far faster than per-folder listings
  if (((Get-Date) - $script:dirCacheAt).TotalSeconds -lt 1) { return $script:dirCache }
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
  if (-not $lg -or $lg.LastWriteTime -lt (Get-Date).AddMinutes(-2)) { return 0 }   # stale log = DS idle between mods
  $line = Get-Content $lg.FullName -Tail 60 | Select-String 'Download speed ([0-9.]+) KB/s' | Select-Object -Last 1
  if ($line) { [Math]::Round([double]$line.Matches[0].Groups[1].Value * 1024) } else { 0 }
}

function Get-Status {
  $dirs = Get-DirMap
  # only batch mods count toward progress; dependency mods the DS auto-pulls
  # have no sizeMap entry and would otherwise push doneB past totalB
  $doneBytes = ($dirs.GetEnumerator() | Where-Object { $sizeMap.ContainsKey($_.Key) } |
    ForEach-Object { [double]$_.Value.bytes } | Measure-Object -Sum).Sum

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
    @{ id = $_.Key; name = $_.Value.name; b = [double]$_.Value.bytes; expB = $exp;
       pct = if ($exp) { [Math]::Min(100, [int](100 * $_.Value.bytes / $exp)) } else { 0 } }
  }

  # all completed mods, newest first (full list - the page shows every one).
  # ids go with them: sync-addons mirrors exactly this set (single completion rule)
  $recent = @($dirs.GetEnumerator() | Where-Object { $completed.ContainsKey($_.Key) } |
    Sort-Object { $_.Value.mtime } -Descending) | ForEach-Object {
    @{ id = $_.Key; name = $_.Value.name; b = [double]$_.Value.bytes }
  }

  @{ running = [bool](Get-DS); speedB = Get-GlobalSpeed
     doneB = [double]$doneBytes; totalB = [double]$TotalBytes
     pct = [Math]::Min(100, [int](100 * $doneBytes / $TotalBytes))
     doneCount = $doneCount; totalMods = $sizeMap.Count
     active = @($active); recent = @($recent); cl = (Get-ClientIds); verify = $verify }
}

if ($Check) {
  try { Get-Status | ConvertTo-Json -Depth 5 | Out-String -Width 300 }
  catch { "GET-STATUS FAILED: $($_.Exception.Message)"; "at: $($_.InvocationInfo.PositionMessage)" }
  exit 0
}

function Start-DS {
  if (Get-DS) { return 'already running' }
  # the 1 MB download-list trap: trimming is lossless (DS skips done mods anyway),
  # skipping it makes the DS insta-crash ~30 s after a false "started"
  & "$PSScriptRoot\trim-config.ps1" | Out-Null
  $dsArgs = "-config `"$Cfg`" -profile `"$Profile`""
  foreach ($try in 1, 2) {
    Start-Process -FilePath $Exe -ArgumentList $dsArgs `
      -WorkingDirectory "$Root\armar-server" -WindowStyle Hidden
    Start-Sleep 25   # the DS either settles into downloading or dies within ~20 s
    if (Get-DS) { return 'started' }
  }
  $lg = Get-Log
  $why = if ($lg) { @(Get-Content $lg.FullName -Tail 20 -ErrorAction SilentlyContinue |
    Select-String 'error|ERROR' | Select-Object -Last 2 | ForEach-Object { $_.Line.Trim() }) -join ' | ' }
  "FAILED to start$(if ($why) { " - last log: $why" } else { ' - no log written, check serverprofile\logs' })"
}

function Stop-DS {
  $p = Get-DS
  if (-not $p) { return 'not running' }
  $p | Stop-Process -Force
  Start-Sleep 1
  'paused - progress kept'
}

function Invoke-Verify {
  # shortcut: verifies only the batch mods against Workshop sizes; dependency
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
    else { $suspects += @{ name = $d.name; expB = [double]$exp; actB = [double]$d.bytes } }
  }
  $script:verify = @{ at = (Get-Date -f 'HH:mm:ss'); ok = $ok; partial = $partial
                      pending = $pending; suspects = $suspects }
  "verify: $ok ok, $partial partial, $pending pending, $($suspects.Count) suspects"
}

function Get-HaveIds {
  # on disk = COMPLETED in the DS profile (same rule as Get-Status: assembled AND
  # size matches - the DS writes the 3 marker files before the data paks, so a
  # killed download would otherwise be treated as done and never re-fetched),
  # or present in the client addons folder
  $have = @{}
  foreach ($e in (Get-DirMap).GetEnumerator()) {
    $sm = $sizeMap[$e.Key]; $exp = if ($sm) { [double]$sm.bytes } else { 0 }
    if ($e.Value.assembled -and (-not $exp -or [Math]::Abs($e.Value.bytes - $exp) -le [Math]::Max(2MB, 0.02 * $exp))) {
      $have[$e.Key] = $true
    }
  }
  foreach ($id in (Get-ClientIds)) { $have[$id] = $true }
  $have
}

function Invoke-QueueServer([string]$Id) {
  # reorder the queue: this server's missing mods download first, the rest of
  # the batch follows unchanged - nothing is dropped or paused
  $srv = @($serverList | Where-Object { $_.id -eq $Id })[0]
  if (-not $srv) { throw 'unknown server id' }
  $name = if ($srv.PSObject.Properties['key'] -and $srv.key) { [string]$srv.key } else { ([string]$srv.name -split '\|')[0].Trim() }
  $have = Get-HaveIds
  $first = @($srv.mods | Where-Object { -not $have.ContainsKey($_.id) } |
    ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
  if (-not $first) { return "nothing to do - all $($srv.mods.Count) mods are already on disk" }
  $j = Get-Content $Cfg -Raw | ConvertFrom-Json
  $ids = @($first | ForEach-Object { $_.modId })
  $rest = @($j.game.mods | Where-Object { $ids -notcontains $_.modId })
  $j.game.mods = @($first + $rest)
  $j | ConvertTo-Json -Depth 5 | Set-Content $Cfg -Encoding UTF8
  Stop-DS | Out-Null
  $r = Start-DS
  "queue reordered: $($first.Count) missing mods of '$name' download first, the other $($rest.Count) pending mods follow ($r)"
}

function Invoke-ResumeBatch {
  # the full batch is deterministic: every sizeMap mod not yet on disk
  $have = Get-HaveIds
  $mods = @($sizeMap.Keys | Where-Object { -not $have.ContainsKey($_) } |
    ForEach-Object { [PSCustomObject]@{ modId = $_; name = [string]$sizeMap[$_].name } })
  $j = Get-Content $Cfg -Raw | ConvertFrom-Json
  $j.game.mods = $mods
  $j | ConvertTo-Json -Depth 5 | Set-Content $Cfg -Encoding UTF8
  Stop-DS | Out-Null
  $r = Start-DS
  "full batch resumed: $($mods.Count) mods remaining ($r)"
}

function Invoke-MakePreset([string]$Id) {
  $out = & "$PSScriptRoot\make-preset.ps1" -ServerId $Id
  ($out | Out-String).Trim()
}

function Get-Browse([string]$q) {
  # live server list from the public reforgermods API, cached 15 s per query
  $key = $q.ToLower()
  if ($script:bCache[$key] -and ((Get-Date) - $script:bCacheAt[$key]).TotalSeconds -lt 15) { return $script:bCache[$key] }
  $u = "$ApiBase/servers?includeOffline=true"
  if ($q) { $u += "&search=$([uri]::EscapeDataString($q))" }
  $r = Invoke-RestMethod -Uri $u -Headers $ApiH -TimeoutSec 30
  $list = @($r.data | Sort-Object online, players -Descending |
    Select-Object -First 60 | ForEach-Object {
      [PSCustomObject]@{ id = $_.id; name = $_.name; players = $_.players; maxPlayers = $_.maxPlayers
                         region = $_.region; online = [bool]$_.online; modCount = $_.modCount
                         scenarioName = $_.scenarioName } })
  $script:bCache[$key] = $list; $script:bCacheAt[$key] = Get-Date
  $list
}

function Get-Detail([string]$Id) {
  # one server with its full modlist (the API sends exact Workshop sizes), cached 30 s
  if ($script:dCache[$Id] -and ((Get-Date) - $script:dCacheAt[$Id]).TotalSeconds -lt 30) { return $script:dCache[$Id] }
  $d = Invoke-RestMethod -Uri "$ApiBase/servers/$Id" -Headers $ApiH -TimeoutSec 30
  if (-not $d.server -or -not @($d.server.mods).Count) { throw 'server has no modlist (offline or password protected)' }
  $script:dCache[$Id] = $d.server; $script:dCacheAt[$Id] = Get-Date
  $d.server
}

function Invoke-AddServer([string]$Id) {
  # add a server from the live browser: queue its missing mods at the END of the
  # batch (adding must not jump the queue), with real sizes from the API
  $s = Get-Detail $Id
  if ($s.passwordProtected) { return 'server is password protected - its modlist is not public' }
  $name = ([string]$s.name -split '\|')[0].Trim()
  if ($name.Length -gt 60) { $name = $name.Substring(0, 60).Trim() }
  $have = Get-HaveIds
  foreach ($m in (Get-Content $Cfg -Raw | ConvertFrom-Json).game.mods) { $have[$m.modId] = $true }
  $new = @($s.mods | Where-Object { -not $have.ContainsKey($_.id) })
  if (-not $new) { return "nothing to add - all $(@($s.mods).Count) mods of '$name' are on disk or queued" }

  $j = Get-Content $Cfg -Raw | ConvertFrom-Json
  $j.game.mods = @($j.game.mods) + @($new | ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
  $j | ConvertTo-Json -Depth 5 | Set-Content $Cfg -Encoding UTF8

  # merge the real sizes into the sizes file (merge-only: never replace it)
  $sz = Get-Content $Sizes -Raw | ConvertFrom-Json
  foreach ($m in $new) {
    if (-not $sizeMap.ContainsKey($m.id)) {
      $sizeMap[$m.id] = @{ name = $m.name; bytes = [double]$m.size; exact = [bool]$m.sizeKnown }
      $sz.mods | Add-Member -NotePropertyName $m.id -NotePropertyValue ([PSCustomObject]@{ name = $m.name; bytes = [double]$m.size; exact = [bool]$m.sizeKnown }) -Force
    }
  }
  $script:TotalBytes = ($sizeMap.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
  $sz.totalBytes = [double]$script:TotalBytes
  $sz | ConvertTo-Json -Depth 4 | Set-Content $Sizes -Encoding UTF8

  # show the new server in the Servers card immediately
  $script:serverList = @($serverList) + @([PSCustomObject]@{ id = $Id; name = $s.name; mods = @($s.mods | ForEach-Object {
    [PSCustomObject]@{ id = $_.id; name = $_.name; e = [double]$_.size } }) })

  $gb = [Math]::Round(($new | ForEach-Object { [double]$_.size } | Measure-Object -Sum).Sum / 1GB, 2)
  Stop-DS | Out-Null
  $r = Start-DS
  "added '$name': $($new.Count) new mods (~$gb GB) queued at the end, $(@($s.mods).Count - $new.Count) already on disk ($r)"
}

# per-run token: the six state-changing endpoints only answer requests that carry
# it, so another website open in the browser cannot drive this server (CSRF)
$token = [guid]::NewGuid().ToString('N')
$mutating = '/start','/pause','/verify','/queue-server','/resume-batch','/make-preset','/add-server'

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
 button.mini{padding:2px 10px;font-size:12px;margin:0 0 0 6px} button.mini.grey{background:#4a4e58} button.mini.amber{background:#b3872e}
 button:disabled{opacity:.5;cursor:default}
 input{background:#26282e;border:1px solid #3a3d45;color:#d6d8de;border-radius:7px;padding:8px 12px;font-size:14px;width:420px}
 ul{list-style:none;margin:6px 0 0;padding:0;font-size:13px}
 li{padding:3px 0;border-bottom:1px solid #26282e}
 details{margin:2px 0} summary{cursor:pointer;font-size:13px;padding:3px 0;color:#fff}
 #srv ul,#bs ul{margin:4px 0 0 16px}
 #bs .bs{margin:4px 0 0 16px}
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
<div class="card"><h2 style="font-size:15px;margin:0 0 8px;color:#fff">Server browser <span class="dim">live</span></h2>
 <div><input id="bq" placeholder="search servers (e.g. PVE, Cold Front, ArmaDudes)..." onkeydown="if(event.key==='Enter')browse()"><button onclick="browse()">Search</button></div>
 <div id="bs" class="dim" style="margin-top:8px">type something and hit Search to list live servers</div>
</div>
<div class="card"><h2 style="font-size:15px;margin:0 0 4px;color:#fff">Servers <span id="srvcount" class="dim"></span></h2><div id="srv" class="dim">loading server lists...</div></div>
<div class="card"><h2 style="font-size:15px;margin:0 0 4px;color:#fff">Completed <span id="reccount" class="dim"></span></h2><ul id="rec"></ul></div>
<script>
const T='__T__';
function esc(x){return String(x).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function sz(b){return b>=1073741824?(b/1073741824).toFixed(2)+' GB':b>=1048576?(b/1048576).toFixed(1)+' MB':b>=1024?(b/1024).toFixed(1)+' KB':Math.round(b)+' B'}
let SRV=null,BR=null,lastKey='';
async function loadSrv(){try{SRV=await (await fetch('/servers')).json();lastKey='';}catch(e){}}
function renderSrv(D,A,B){
 if(!SRV)return;
 document.getElementById('srvcount').textContent='('+SRV.servers.length+')';
 document.getElementById('srv').innerHTML=SRV.servers.map(v=>{
  const done=v.mods.filter(m=>D[m.id]).length;
  return '<details><summary>'+esc(v.name)+' <span class="dim">'+done+' / '+v.mods.length+' downloaded</span>'+
   '<button class="mini" onclick="queueSrv(\''+v.id+'\',event)">Queue first</button>'+
   '<button class="mini amber" onclick="presetSrv(\''+v.id+'\',event)">Make preset</button></summary><ul>'+
   v.mods.map(m=>{
    const t=D[m.id]?'<span class="ok">&#10003;</span>':A[m.id]?'<span class="warn">&#10227;</span>':'<span class="dim">&#8226;</span>';
    const s2=B[m.id]!=null?sz(B[m.id]):(m.e>0?sz(m.e):'');
    return '<li>'+t+' '+esc(m.name)+' <span class="dim">'+s2+'</span></li>';
   }).join('')+'</ul></details>';
 }).join('');
}
async function browse(){
 const q=document.getElementById('bq').value.trim();
 const el=document.getElementById('bs');
 el.textContent='searching live servers...';
 try{
  const r=await (await fetch('/browse?q='+encodeURIComponent(q))).json();
  BR=r.servers; renderBrowse();
 }catch(e){ el.innerHTML='<span class="bad">search failed: '+esc(String(e))+'</span>'; }
}
function renderBrowse(){
 const el=document.getElementById('bs');
 if(!BR||!BR.length){el.innerHTML='<span class="dim">no servers found</span>';return;}
 el.innerHTML=BR.map(v=>
  '<details ontoggle="bsToggle(this,\''+v.id+'\')"><summary>'+esc(v.name)+
  ' <span class="dim">'+v.players+'/'+v.maxPlayers+(v.online?'':' &middot; offline')+' &middot; '+v.modCount+' mods</span>'+
  '<button class="mini" onclick="addSrv(\''+v.id+'\',event)">Add server</button></summary>'+
  '<div class="bs" data-id="'+v.id+'"><span class="dim">loading modlist...</span></div></details>').join('');
}
function bsToggle(d,id){ if(d.open&&!d.dataset.l){d.dataset.l=1;loadBS(id,d);} }
async function loadBS(id,d){
 const box=d.querySelector('.bs');
 try{
  const j=await (await fetch('/browse-server?id='+id)).json();
  const ok=j.mods.filter(m=>m.have).length;
  box.innerHTML='<div class="dim">'+ok+' / '+j.mods.length+' mods on disk - '+sz(j.missingBytes||0)+' to download</div><ul>'+
   j.mods.map(m=>'<li>'+(m.have?'<span class="ok">&#10003;</span>':'<span class="dim">&#8226;</span>')+' '+esc(m.name)+' <span class="dim">'+(m.expB>0?sz(m.expB):'')+'</span></li>').join('')+'</ul>';
 }catch(e){ box.innerHTML='<span class="bad">'+esc(String(e).replace('Error: ',''))+'</span>'; }
}
async function addSrv(id,ev){
 ev.stopPropagation();
 const b=ev.target; b.disabled=true; b.textContent='...';
 if(confirm('Add this server? Its missing mods are queued at the END of the current download queue.'))await post('add-server?id='+id);
 b.disabled=false; b.textContent='Add server';
 loadSrv();
}
async function tick(){
 try{
  if(!SRV)loadSrv();
  const s=await (await fetch('/status')).json();
  const boot=document.getElementById('boot'); if(boot)boot.remove();
  document.getElementById('st').innerHTML=s.running
    ?'<span class="dot" style="background:#4cc35e"></span><span class="ok">running</span>'
    :'<span class="dot" style="background:#e06c6c"></span><span class="bad">stopped</span>';
  document.getElementById('gbtxt').textContent=sz(s.doneB)+' / '+sz(s.totalB);
  document.getElementById('tbar').style.width=s.pct+'%';
  document.getElementById('spd').textContent=s.running?(s.speedB>0?sz(s.speedB)+'/s':'idle'):'paused';
  document.getElementById('cnt').textContent=s.doneCount+' / '+s.totalMods+' mods assembled';
  const eta=(s.speedB>51200)?Math.round((s.totalB-s.doneB)/s.speedB/60)+' min left':'--';
  document.getElementById('etabox').textContent=eta;
  const ac=document.getElementById('actcard');
  if(s.active.length){ac.style.display='block';
   document.getElementById('act').innerHTML=s.active.map(a=>
    '<div class="row"><span>'+esc(a.name)+'</span><span class="dim">'+(a.expB>0?(sz(a.b)+' / '+sz(a.expB)):sz(a.b)+' (dependency, size unknown)')+'</span></div>'+
    (a.expB>0?'<div class="bar amber"><div style="width:'+a.pct+'%"></div></div>':'')).join('');
  } else ac.style.display='none';
  const D={},A={},B={};
  s.recent.forEach(r=>{D[r.id]=1;B[r.id]=r.b});
  s.active.forEach(a=>{A[a.id]=1});
  (s.cl||[]).forEach(id=>{D[id]=1});   // installed client-side before the batch counts as on disk
  const key=s.recent.length+'|'+s.active.map(a=>a.id).join(',');
  if(key!==lastKey){          // lists only re-render when something actually finished/started
   lastKey=key;
   document.getElementById('reccount').textContent='('+s.recent.length+')';
   document.getElementById('rec').innerHTML=s.recent.length
    ?s.recent.map(r=>'<li class="ok">&#10003; '+esc(r.name)+' <span class="dim">'+sz(r.b)+'</span></li>').join('')
    :'<li class="dim">nothing finished yet</li>';
   renderSrv(D,A,B);
  }
  const v=document.getElementById('vres');
  if(s.verify){v.style.display='block';const x=s.verify;
   let t='<b>Verify '+x.at+'</b> - <span class="ok">'+x.ok+' ok</span>, '+x.partial+' partial, '+x.pending+' pending';
   if(x.suspects&&x.suspects.length){t+='<br><span class="bad">Size mismatch (re-download candidates):</span><ul>'+
     x.suspects.map(z=>'<li class="bad">'+esc(z.name)+' - expected '+sz(z.expB)+', on disk '+sz(z.actB)+'</li>').join('')+'</ul>';}
   else t+='<br><span class="ok">No size mismatches - installed mods look intact.</span>';
   v.innerHTML=t;}
 }catch(e){}
}
async function post(w){
 try{
  const r=await fetch('/'+w+(w.indexOf('?')>=0?'&':'?')+'t='+T,{method:'POST'});
  const j=await r.json();
  if(j.msg)alert(j.msg);
  if(j.error)alert('failed: '+j.error);
  await tick();
 }catch(e){alert('failed: '+e); await tick();}
}
async function queueSrv(id,ev){
 ev.stopPropagation();
 const b=ev.target; b.disabled=true; b.textContent='...';
 await post('queue-server?id='+id);
 b.disabled=false; b.textContent='Queue first';
}
async function presetSrv(id,ev){
 ev.stopPropagation();
 const b=ev.target; b.disabled=true; b.textContent='...';
 if(confirm('Create an Arma Reforger launcher preset for this server? Installed mods only, and the game must be closed.'))await post('make-preset?id='+id);
 b.disabled=false; b.textContent='Make preset';
}
async function act(w){
 const b=event?event.target:null; if(b){b.disabled=true;b.textContent='...';}
 await post(w);
 if(b){b.disabled=false;b.textContent=w==='start'?'Start / Resume':w==='pause'?'Pause':'Verify mods';}
}
loadSrv(); tick(); setInterval(tick,500);
</script></body></html>
'@

$l = [System.Net.HttpListener]::new(); $l.Prefixes.Add($Url)
try { $l.Start() }
catch {
  # port busy: a just-killed dashboard's keep-alive sockets linger for a while.
  # retry once before concluding another instance is actually serving.
  Start-Sleep 5
  try { $l = [System.Net.HttpListener]::new(); $l.Prefixes.Add($Url); $l.Start() }
  catch {
    Write-Host 'dashboard already running - opening browser' -ForegroundColor Cyan
    Start-Process $Url
    exit 0
  }
}
Write-Host '=== Arma Reforger Mods - web dashboard ===' -ForegroundColor White
Write-Host "open: $Url   (keep this window open; closing it only stops the UI, not the download)" -ForegroundColor Cyan
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',`
  '-File',"$PSScriptRoot\sync-addons.ps1",'-Loop'   # auto-mirror completed mods into client addons
Start-Process $Url

while ($l.IsListening) {
  $ctx = $l.GetContext()
  try {
    $msg = $null   # must reset per request or it leaks into the next response body
    $path = $ctx.Request.Url.AbsolutePath
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    if ($path -in $mutating -and $ctx.Request.QueryString['t'] -ne $token) {
      $ctx.Response.StatusCode = 403
      $b = [Text.Encoding]::UTF8.GetBytes('{"error":"bad or missing token"}')
      $ctx.Response.ContentType = 'application/json'
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      continue
    }
    switch ($path) {
      '/' {
        $b = [Text.Encoding]::UTF8.GetBytes($html.Replace('__T__', $token))
        $ctx.Response.ContentType = 'text/html; charset=utf-8'
        $ctx.Response.ContentLength64 = $b.Length
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/status' {
        $b = [Text.Encoding]::UTF8.GetBytes((Get-Status | ConvertTo-Json -Depth 5 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/servers' {
        $b = [Text.Encoding]::UTF8.GetBytes((@{ servers = $serverList } | ConvertTo-Json -Depth 5 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/browse' {
        $b = [Text.Encoding]::UTF8.GetBytes((@{ servers = (Get-Browse $ctx.Request.QueryString['q']) } | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/browse-server' {
        $s = Get-Detail $ctx.Request.QueryString['id']
        $have = Get-HaveIds
        $rows = @($s.mods | ForEach-Object {
          $exp = if ($sizeMap.ContainsKey($_.id)) { [double]$sizeMap[$_.id].bytes } else { [double]$_.size }
          [PSCustomObject]@{ id = $_.id; name = $_.name; expB = $exp; have = [bool]$have.ContainsKey($_.id) } })
        $missing = @($rows | Where-Object { -not $_.have })
        $out = @{ name = $s.name; online = [bool]$s.online; mods = $rows
                  haveCount = @($rows | Where-Object { $_.have }).Count
                  missingBytes = [double]($missing | ForEach-Object { $_.expB } | Measure-Object -Sum).Sum }
        $b = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 4 -Compress))
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length)
      }
      '/start'  { $msg = Start-DS;        Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/pause'  { $msg = Stop-DS;         Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Yellow }
      '/verify' { $msg = Invoke-Verify;   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      '/queue-server' { $msg = Invoke-QueueServer $ctx.Request.QueryString['id']; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/resume-batch' { $msg = Invoke-ResumeBatch; Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      '/make-preset'  { $msg = Invoke-MakePreset $ctx.Request.QueryString['id'];  Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Cyan }
      '/add-server'   { $msg = Invoke-AddServer $ctx.Request.QueryString['id'];   Write-Host "[$(Get-Date -f HH:mm:ss)] $msg" -ForegroundColor Green }
      default   { $msg = $null; $ctx.Response.StatusCode = 404 }
    }
    if ($msg) {
      $b = [Text.Encoding]::UTF8.GetBytes((@{ ok = $true; msg = [string]$msg } | ConvertTo-Json -Compress))
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
