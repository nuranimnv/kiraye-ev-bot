param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $scriptDir 'seen.json'

$botToken = $env:TELEGRAM_BOT_TOKEN
$chatIds = @($env:TELEGRAM_CHAT_ID) | Where-Object { $_ }
if (-not $botToken -or $chatIds.Count -eq 0) {
    throw "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID env variables are not set"
}

function Write-Log($msg) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
}

function Send-Telegram([string]$text) {
    $uri = "https://api.telegram.org/bot$botToken/sendMessage"
    foreach ($cid in $chatIds) {
        $payload = @{ chat_id = $cid; text = $text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        try {
            Invoke-RestMethod -Uri $uri -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' | Out-Null
        } catch {
            Write-Log "Telegram send error (chat $cid): $_"
        }
    }
}

# ---- load state ----
$binaSeenList = New-Object System.Collections.Generic.List[string]
$ev10SeenList = New-Object System.Collections.Generic.List[string]
$firstRun = $true
$threeRoomInit = $false

if (Test-Path $stateFile) {
    $firstRun = $false
    try {
        $state = Get-Content -Raw -Path $stateFile -Encoding UTF8 | ConvertFrom-Json
        if ($state.bina) { $binaSeenList.AddRange([string[]]$state.bina) }
        if ($state.ev10) { $ev10SeenList.AddRange([string[]]$state.ev10) }
        if ($state.threeRoomInit) { $threeRoomInit = $true }
    } catch {
        Write-Log "State load error, starting fresh: $_"
        $firstRun = $true
    }
}
$binaSeenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$binaSeenList)
$ev10SeenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ev10SeenList)

$newMessages = New-Object System.Collections.Generic.List[string]

# ---- bina.az ---- (location ids: 20 Yanvar=5, Memar Ecemi=59, Nizami=35, Elmler Akademiyasi=34, Insaatcilar=7, N.Nerimanov=1, Genclik=2, Nesimi=60)
function Get-BinaUrl([string]$filterExtra, [string]$roomId) {
    $vars = '{"first":30,"filter":{"cityId":"1","categoryId":"1","paidDaily":false,"locationIds":["5","59","35","34","7","1","2","60"],"roomIds":["' + $roomId + '"],"leased":true' + $filterExtra + '},"sort":"BUMPED_AT_DESC"}'
    $ext = '{"persistedQuery":{"version":1,"sha256Hash":"b781511a943a4d710eefdf811a24dd4ae353e55d836952603ce0b37fde97d073"}}'
    return 'https://bina.az/graphql?operationName=SearchItems&variables=' + [uri]::EscapeDataString($vars) + '&extensions=' + [uri]::EscapeDataString($ext)
}

function Invoke-BinaSearch([string]$url, [string]$label, [bool]$silent) {
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{ 'apollo-require-preflight' = 'true'; 'User-Agent' = 'Mozilla/5.0' }
        $edges = $resp.data.itemsConnection.edges
        Write-Log "bina.az ($label): fetched $($edges.Count) items"
        foreach ($edge in $edges) {
            $n = $edge.node
            $id = "bina-$($n.id)"
            if (-not $binaSeenSet.Contains($id)) {
                $binaSeenSet.Add($id) | Out-Null
                $binaSeenList.Add($id)
                if (-not $silent) {
                    $text = "Yeni kiraye elani (bina.az)`n$($n.price.total) AZN/ay`n$($n.rooms) otaqli, $($n.area.value) m2, $($n.floor)/$($n.floors) mertebe`n$($n.location.fullName)`nhttps://bina.az$($n.path)"
                    $newMessages.Add($text)
                }
            }
        }
    } catch {
        Write-Log "bina.az ($label) fetch error: $_"
    }
}

Invoke-BinaSearch (Get-BinaUrl ',"priceTo":550' '2') '2 otaq' $false
Invoke-BinaSearch (Get-BinaUrl ',"priceFrom":590,"priceTo":660,"areaFrom":55' '3') '3 otaq' (-not $threeRoomInit)

# ---- ev10.az ---- (subway ids: 20 Yanvar=200, Memar Ecemi=201, Nizami=197, Elmler Akademiyasi=198, Insaatcilar=199, N.Nerimanov=188, Genclik=187, Nesimi=202)
$ev10Base = 'https://ev10.az/api/v1.0/postings?sale_type=LEASE&page_number=1&media_type=image&lease_type=MONTHLY&search_type=home_page&sort_by=date_desc&page_size=50&location_ids=200&location_ids=201&location_ids=197&location_ids=198&location_ids=199&location_ids=188&location_ids=187&location_ids=202'

function Invoke-Ev10Search([string]$url, [string]$label, [bool]$silent) {
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        $postings = $resp.postings
        Write-Log "ev10.az ($label): fetched $($postings.Count) postings"
        foreach ($p in $postings) {
            $id = "ev10-$($p.id)"
            if (-not $ev10SeenSet.Contains($id)) {
                $ev10SeenSet.Add($id) | Out-Null
                $ev10SeenList.Add($id)
                if (-not $silent) {
                    $metroName = if ($p.subway_station) { $p.subway_station.name } else { $p.district }
                    $text = "Yeni kiraye elani (ev10.az)`n$($p.price) AZN/ay`n$($p.rooms) otaqli, $($p.area) m2, $($p.floor)/$($p.total_floors) mertebe`n$metroName`nhttps://ev10.az/posting/$($p.id)"
                    $newMessages.Add($text)
                }
            }
        }
    } catch {
        Write-Log "ev10.az ($label) fetch error: $_"
    }
}

Invoke-Ev10Search ($ev10Base + '&max_price=550&min_rooms=2&max_rooms=2') '2 otaq' $false
Invoke-Ev10Search ($ev10Base + '&min_price=590&max_price=660&min_area=55&min_rooms=3&max_rooms=3') '3 otaq' (-not $threeRoomInit)

# ---- notify ----
if ($firstRun) {
    Send-Telegram "Bot aktivlesdi (GitHub Actions). $($binaSeenList.Count + $ev10SeenList.Count) movcud elan qeyde alindi. Bundan sonra yalniz yeni elanlar barede bildiris gonderilecek."
    Write-Log "First run: recorded $($binaSeenList.Count + $ev10SeenList.Count) baseline ids, no notifications sent"
} else {
    foreach ($msg in $newMessages) {
        Send-Telegram $msg
        Start-Sleep -Milliseconds 400
    }
    Write-Log "Sent $($newMessages.Count) notifications"
}

# ---- trim & save state ----
$maxKeep = 1500
if ($binaSeenList.Count -gt $maxKeep) { $binaSeenList.RemoveRange(0, $binaSeenList.Count - $maxKeep) }
if ($ev10SeenList.Count -gt $maxKeep) { $ev10SeenList.RemoveRange(0, $ev10SeenList.Count - $maxKeep) }

$stateOut = @{ bina = @($binaSeenList); ev10 = @($ev10SeenList); threeRoomInit = $true }
$stateOut | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8

Write-Output "Done. New: $($newMessages.Count). Bina seen: $($binaSeenList.Count). Ev10 seen: $($ev10SeenList.Count)."
