param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $scriptDir 'seen.json'

$botToken = $env:TELEGRAM_BOT_TOKEN
$chatId = $env:TELEGRAM_CHAT_ID
if (-not $botToken -or -not $chatId) {
    throw "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID env variables are not set"
}

$metros = @('20 Yanvar', 'Memar Əcəmi', 'Nizami', 'Elmlər Akademiyası', 'İnşaatçılar', 'Nəriman Nərimanov', 'N.Nərimanov', 'Gənclik')

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
$tapSeenList = New-Object System.Collections.Generic.List[string]
$firstRun = $true

if (Test-Path $stateFile) {
    $firstRun = $false
    try {
        $state = Get-Content -Raw -Path $stateFile -Encoding UTF8 | ConvertFrom-Json
        if ($state.bina) { $binaSeenList.AddRange([string[]]$state.bina) }
        if ($state.tap) { $tapSeenList.AddRange([string[]]$state.tap) }
    } catch {
        Write-Log "State load error, starting fresh: $_"
        $firstRun = $true
    }
}
$binaSeenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$binaSeenList)
$tapSeenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$tapSeenList)

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

# ---- tap.az ----
$tapUrl = 'https://tap.az/elanlar/dasinmaz-emlak/menziller?categoryId=Z2lkOi8vdGFwL0NhdGVnb3J5LzYzNQ&q%5Bis_shop%5D=&q%5Bregion_id%5D=420&order=date_desc&keywords_source=typewritten&q%5Bprice%5D%5B%5D=&q%5Bprice%5D%5B%5D=550&p%5B740%5D=3724&p%5B736%5D%5B%5D=2&p%5B736%5D%5B%5D=2'

try {
    $resp = Invoke-WebRequest -Uri $tapUrl -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
    $html = $resp.Content
    $m = [regex]::Match($html, '<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) {
        $json = $m.Groups[1].Value | ConvertFrom-Json
        $apollo = $json.props.pageProps.apolloState
        $adKeys = $apollo.PSObject.Properties.Name | Where-Object { $_ -match '^Ad:' }
        $ads = foreach ($k in $adKeys) { $apollo.$k }
        $ads = $ads | Sort-Object { [datetime]$_.updatedAt } -Descending
        Write-Log "tap.az: fetched $($ads.Count) ads"
        foreach ($ad in $ads) {
            $title = $ad.title
            $matched = $false
            foreach ($metro in $metros) {
                if ($title -match [regex]::Escape($metro)) { $matched = $true; break }
            }
            if ($matched) {
                $id = "tap-$($ad.legacyResourceId)"
                if (-not $tapSeenSet.Contains($id)) {
                    $tapSeenSet.Add($id) | Out-Null
                    $tapSeenList.Add($id)
                    $text = "Yeni kiraye elani (tap.az)`n$($ad.price) AZN/ay`n$title`nhttps://tap.az$($ad.path)"
                    $newMessages.Add($text)
                }
            }
        }
    } else {
        Write-Log "tap.az: __NEXT_DATA__ not found"
    }
} catch {
    Write-Log "tap.az fetch error: $_"
}

# ---- notify ----
if ($firstRun) {
    Send-Telegram "Bot aktivlesdi (GitHub Actions). $($binaSeenList.Count + $tapSeenList.Count) movcud elan qeyde alindi. Bundan sonra yalniz yeni elanlar barede bildiris gonderilecek."
    Write-Log "First run: recorded $($binaSeenList.Count + $tapSeenList.Count) baseline ids, no notifications sent"
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
if ($tapSeenList.Count -gt $maxKeep) { $tapSeenList.RemoveRange(0, $tapSeenList.Count - $maxKeep) }

$stateOut = @{ bina = @($binaSeenList); tap = @($tapSeenList) }
$stateOut | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8

Write-Output "Done. New: $($newMessages.Count). Bina seen: $($binaSeenList.Count). Tap seen: $($tapSeenList.Count)."
