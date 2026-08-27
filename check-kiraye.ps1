param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $scriptDir 'seen.json'

$botToken = $env:TELEGRAM_BOT_TOKEN
$chatId = $env:TELEGRAM_CHAT_ID
if (-not $botToken -or -not $chatId) {
    throw "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID env variables are not set"
}

function Write-Log($msg) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
}

function Send-Telegram([string]$text) {
    $uri = "https://api.telegram.org/bot$botToken/sendMessage"
    $payload = @{ chat_id = $chatId; text = $text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        Invoke-RestMethod -Uri $uri -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' | Out-Null
    } catch {
        Write-Log "Telegram send error: $_"
    }
}

# ---- load state ----
$binaSeenList = New-Object System.Collections.Generic.List[string]
$firstRun = $true

if (Test-Path $stateFile) {
    $firstRun = $false
    try {
        $state = Get-Content -Raw -Path $stateFile -Encoding UTF8 | ConvertFrom-Json
        if ($state.bina) { $binaSeenList.AddRange([string[]]$state.bina) }
    } catch {
        Write-Log "State load error, starting fresh: $_"
        $firstRun = $true
    }
}
$binaSeenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$binaSeenList)

$newMessages = New-Object System.Collections.Generic.List[string]

# ---- bina.az ----
$binaUrl = 'https://bina.az/graphql?operationName=SearchItems&variables=%7B%22first%22%3A30%2C%22filter%22%3A%7B%22cityId%22%3A%221%22%2C%22categoryId%22%3A%221%22%2C%22paidDaily%22%3Afalse%2C%22locationIds%22%3A%5B%225%22%2C%2259%22%2C%2235%22%2C%2234%22%2C%227%22%2C%221%22%2C%222%22%5D%2C%22roomIds%22%3A%5B%222%22%5D%2C%22priceTo%22%3A550%2C%22leased%22%3Atrue%7D%2C%22sort%22%3A%22BUMPED_AT_DESC%22%7D&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22b781511a943a4d710eefdf811a24dd4ae353e55d836952603ce0b37fde97d073%22%7D%7D'

try {
    $resp = Invoke-RestMethod -Uri $binaUrl -Headers @{ 'apollo-require-preflight' = 'true'; 'User-Agent' = 'Mozilla/5.0' }
    $edges = $resp.data.itemsConnection.edges
    Write-Log "bina.az: fetched $($edges.Count) items"
    foreach ($edge in $edges) {
        $n = $edge.node
        $id = "bina-$($n.id)"
        if (-not $binaSeenSet.Contains($id)) {
            $binaSeenSet.Add($id) | Out-Null
            $binaSeenList.Add($id)
            $text = "Yeni kiraye elani (bina.az)`n$($n.price.total) AZN/ay`n$($n.rooms) otaqli, $($n.area.value) m2, $($n.floor)/$($n.floors) mertebe`n$($n.location.fullName)`nhttps://bina.az$($n.path)"
            $newMessages.Add($text)
        }
    }
} catch {
    Write-Log "bina.az fetch error: $_"
}

# ---- notify ----
if ($firstRun) {
    Send-Telegram "Bot aktivlesdi (GitHub Actions). $($binaSeenList.Count) movcud elan qeyde alindi. Bundan sonra yalniz yeni elanlar barede bildiris gonderilecek."
    Write-Log "First run: recorded $($binaSeenList.Count) baseline ids, no notifications sent"
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

$stateOut = @{ bina = @($binaSeenList) }
$stateOut | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8

Write-Output "Done. New: $($newMessages.Count). Bina seen: $($binaSeenList.Count)."
