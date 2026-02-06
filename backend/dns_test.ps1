$target = "ep-snowy-sun-aipedmdn-pooler.c-4.us-east-1.aws.neon.tech"
$dnsServers = @(
    @{ Name = "System Default"; IP = $null },
    @{ Name = "Google (8.8.8.8)"; IP = "8.8.8.8" },
    @{ Name = "Cloudflare (1.1.1.1)"; IP = "1.1.1.1" },
    @{ Name = "OpenDNS (208.67.222.222)"; IP = "208.67.222.222" }
)

Write-Host "Testing DNS resolution for: $target" -ForegroundColor Cyan
Write-Host "---------------------------------------------------"

foreach ($server in $dnsServers) {
    $serverName = $server.Name
    $serverIP = $server.IP
    
    Write-Host "Testing via $serverName..." -NoNewline
    
    try {
        if ($serverIP) {
            $result = Resolve-DnsName -Name $target -Server $serverIP -ErrorAction Stop -Type A
        } else {
            $result = Resolve-DnsName -Name $target -ErrorAction Stop -Type A
        }
        
        if ($result) {
            Write-Host " [OK] Resolved to: $($result.IPAddress)" -ForegroundColor Green
        }
    } catch {
        Write-Host " [FAILED] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nTest complete."
