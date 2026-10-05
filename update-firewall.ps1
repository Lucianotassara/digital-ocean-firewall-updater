# Updates a DigitalOcean firewall so the given TCP ports only accept the current public IP.
# Works on Windows PowerShell 5.1 and PowerShell 7+. No external dependencies.
param(
    [Alias('p')] [string[]]$Ports,   # Comma separated list of ports. Ignored if PORTS is set in .env
    [Alias('c')] [switch]$Cidr,      # Save IP as CIDR like xxx.xxx.xxx.0/24
    [Alias('f')] [switch]$Force,     # Force firewall update
    [Alias('a')] [switch]$Add,       # Add the new IP to the previously saved ones
    [Alias('r')] [switch]$Remove,    # Remove IP addresses on selected ports (leaves only 127.0.0.1)
    [Alias('i')] [string]$Ip,        # Use this IP instead of auto-detecting it
    [Alias('h')] [switch]$Help
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if ($Help) {
    Get-Content $PSCommandPath -TotalCount 12 | Where-Object { $_ -match '^(#|\s+\[Alias)' } | ForEach-Object { $_ -replace '^#\s?', '' }
    exit 0
}

$LastIpFile = Join-Path $PSScriptRoot 'lastIp.txt'

# ---- .env (real environment variables win) ----
$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line -notmatch '^(?:export\s+)?([A-Za-z_]\w*)\s*=(.*)$') { continue }
        $key = $Matches[1]; $val = $Matches[2].Trim()
        if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
        if (-not (Test-Path "Env:$key")) { Set-Item "Env:$key" $val }
    }
}
if (-not $env:PERSONAL_ACCESS_TOKEN) { throw 'PERSONAL_ACCESS_TOKEN is not set (.env)' }
if (-not $env:FIREWALL_ID)           { throw 'FIREWALL_ID is not set (.env)' }

$portsSrc = if ($env:PORTS) { $env:PORTS } else { $Ports -join ',' }
$portList = @($portsSrc -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($portList.Count -eq 0) {
    Write-Host 'You should specify at least one port. Run with --help option to see available options'
    exit 1
}

# ---- helpers ----
function Test-IPv4($s) { $s -match '^(\d{1,3}\.){3}\d{1,3}$' }
function ConvertTo-Cidr($s) { $o = $s.Split('.'); '{0}.{1}.{2}.0/24' -f $o[0], $o[1], $o[2] }

function Get-PublicIp {
    $services = 'https://api4.ipify.org?format=text', 'https://ipv4.icanhazip.com',
                'https://checkip.amazonaws.com', 'https://ipv4.my-ip.io/ip'
    foreach ($url in $services) {
        try {
            $text = ([string](Invoke-RestMethod -Uri $url -TimeoutSec 8)).Trim()
            if (Test-IPv4 $text) { Write-Host "Getting IP from ${url}: $text"; return $text }
        } catch { }
        Write-Warning "Failed to get IP from $url"
    }
    return $null
}

$apiUrl  = "https://api.digitalocean.com/v2/firewalls/$($env:FIREWALL_ID)"
$headers = @{ Authorization = "Bearer $($env:PERSONAL_ACCESS_TOKEN)" }

# ---- main ----
Write-Host "**** $(Get-Date) ****"

if ($Ip) {
    if (-not (Test-IPv4 $Ip)) { throw "Invalid IPv4 address: $Ip" }
    $newIp = $Ip
    Write-Host "Using manually specified IP: $newIp"
} else {
    $newIp = Get-PublicIp
    if (-not $newIp) { Write-Error 'Could not retrieve public IP, aborting.'; exit 1 }
}

$savedIp = ''
if (Test-Path $LastIpFile) { $savedIp = (Get-Content $LastIpFile -Raw).Trim() }
Write-Host "Saved IP Address: $savedIp"

if (-not $Force -and $savedIp -eq $newIp) { Write-Host 'No IP changes'; exit 0 }

$rawIp = $newIp
if ($Cidr) {
    if ($savedIp -and (Test-IPv4 $savedIp) -and (ConvertTo-Cidr $newIp) -eq (ConvertTo-Cidr $savedIp)) {
        Write-Host 'IP has changed but not for CIDR notation'; exit 0
    }
    $newIp = ConvertTo-Cidr $newIp
}
Write-Host 'IP has changed, starting firewall update'

Write-Host 'Getting the firewall from DO API'
$fw = (Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers).firewall
Write-Host "Showing my firewall -> $($fw | ConvertTo-Json -Depth 10 -Compress)"

foreach ($rule in $fw.inbound_rules) {
    if ($rule.protocol -ne 'tcp') {
        Write-Host "Found some none TCP rules: $($rule | ConvertTo-Json -Depth 10 -Compress)"
        continue
    }
    if ($portList -notcontains [string]$rule.ports) { continue }

    if ($Remove)   { $addresses = @('127.0.0.1') }
    elseif ($Add)  { $addresses = @($rule.sources.addresses) + $newIp }
    else           { $addresses = @($newIp) }
    $rule.sources | Add-Member -NotePropertyName addresses -NotePropertyValue $addresses -Force
    Write-Host "   *** Updating source ip for rule on port $($rule.ports): $($addresses -join ',') ***"
}

# Fields the API rejects on PUT; ICMP rules must not specify ports; tcp/udp "0" means all.
foreach ($name in 'id', 'created_at', 'pending_changes', 'status') { $fw.PSObject.Properties.Remove($name) }
foreach ($rule in @($fw.inbound_rules) + @($fw.outbound_rules)) {
    if ($rule.protocol -eq 'icmp') { $rule.PSObject.Properties.Remove('ports') }
    elseif (-not $rule.ports -or $rule.ports -eq '0') {
        $rule | Add-Member -NotePropertyName ports -NotePropertyValue 'all' -Force
    }
}

$body = $fw | ConvertTo-Json -Depth 10 -Compress
Write-Host "Showing updated firewall -> $body"

$resp = Invoke-RestMethod -Uri $apiUrl -Method Put -Headers $headers -ContentType 'application/json' -Body $body
Write-Host "Placing PUT request to DigitalOcean API. RESPONSE: $($resp | ConvertTo-Json -Depth 10 -Compress)"

Set-Content -Path $LastIpFile -Value $rawIp -NoNewline
Write-Host "$rawIp > lastIp.txt"
