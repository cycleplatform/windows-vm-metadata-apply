# ============================================================
# Cycle Windows VM Netconf
# Applies cloud-init "network-config" to Windows NICs
# Compatible with PowerShell 5 (Windows Server)
#
# Copyright (c) 2025 Petrichor Holdings, Inc. (Cycle)
# ============================================================

Write-Host "[Cycle] Applying network configuration..."

# ----------------------------------------------------------------------
# 1. Locate the config-drive containing cloud-init metadata
# ----------------------------------------------------------------------
$cd = Get-CimInstance Win32_LogicalDisk |
      Where-Object { $_.DriveType -eq 5 -and $_.VolumeName -match 'cidata|config-2' }

if (-not $cd) {
    Write-Error "[Cycle] Could not find config-drive."
    exit 1
}

$drive   = $cd.DeviceID
$cfgPath = Join-Path $drive "network-config"

if (-not (Test-Path $cfgPath)) {
    Write-Error "[Cycle] network-config not found on $drive"
    exit 1
}

Write-Host "[Cycle] Found network-config on $drive"


# ----------------------------------------------------------------------
# 2. Minimal YAML parser (PowerShell 5-compatible)
# ----------------------------------------------------------------------
function Convert-YamlSimple {
    param([string]$Yaml)

    $lines = $Yaml -split "`n"
    $root  = @{}
    $stack = @(@{ obj = $root; indent = -1 })

    foreach ($rawLine in $lines) {
        $line = $rawLine.Replace("`r","")
        if ($line.Trim() -eq "" -or $line.Trim().StartsWith("#")) { continue }

        $indent = ($line.Length - $line.TrimStart().Length)
        $trim   = $line.Trim()

        while ($stack[-1].indent -ge $indent) {
            $stack = $stack[0..($stack.Count - 2)]
        }
        $parent = $stack[-1].obj

        # List item "- ..."
        if ($trim -match "^- (.+)$") {
            $val = $matches[1]

            if (-not $parent["_list"]) {
                $parent["_list"] = New-Object System.Collections.ArrayList
            }

            # "- key: value"
            if ($val -match "^([^:]+):\s+(.+)$") {
                $obj = @{}
                $obj[$matches[1]] = $matches[2]
                $parent["_list"].Add($obj) | Out-Null
                $stack += ,@{ obj = $obj; indent = $indent }
                continue
            }

            # "- scalar"
            $parent["_list"].Add($val) | Out-Null
            continue
        }

        # "key:"
        if ($trim -match "^([^:]+):\s*$") {
            $key = $matches[1]
            $obj = @{}
            $parent[$key] = $obj
            $stack += ,@{ obj = $obj; indent = $indent }
            continue
        }

        # "key: value"
        if ($trim -match "^([^:]+):\s+(.+)$") {
            $parent[$matches[1]] = $matches[2]
            continue
        }
    }

    # Fixup: convert "_list" placeholders
    function Fixup($node) {
        foreach ($k in @($node.Keys)) {
            if ($node[$k] -is [System.Collections.IDictionary]) {
                Fixup $node[$k]
                if ($node[$k].Contains("_list")) {
                    $node[$k] = $node[$k]["_list"]
                }
            }
        }
    }

    Fixup $root
    return $root
}

function Normalize-Mac($mac) {
    if (-not $mac) { return "" }
    $m = $mac -replace '-', ':' -replace '\.', ':'
    return $m.ToLower()
}


# ----------------------------------------------------------------------
# 3. Load and parse cloud-init YAML
# ----------------------------------------------------------------------
$yamlText = Get-Content $cfgPath -Raw
$cfg      = Convert-YamlSimple $yamlText

if (-not $cfg["ethernets"]) {
    Write-Error "[Cycle] YAML parsed but no 'ethernets' section found!"
    exit 1
}

$ethernets = $cfg["ethernets"]


# ----------------------------------------------------------------------
# 4. Print ethernet entries so user can confirm mapping
# ----------------------------------------------------------------------
Write-Host "[Cycle] NICs defined in network-config:"
foreach ($key in $ethernets.Keys) {
    $mac = $ethernets[$key]["match"]["macaddress"]
    $set = $ethernets[$key]["set-name"]
    Write-Host "  - $key → MAC $mac → rename '$set'"
}


# ----------------------------------------------------------------------
# 5. Determine rename order (eth1 before eth0)
# ----------------------------------------------------------------------
$renameOrder = $ethernets.Keys | Sort-Object {
    if ($_ -eq "eth1") { return 0 }
    if ($_ -eq "eth0") { return 1 }
    return 2
}


# ----------------------------------------------------------------------
# 6. Convert CIDR prefix → IPv4 dotted-netmask
# ----------------------------------------------------------------------
function PrefixToMask([int]$prefix) {
    $mask = [uint32]0
    for ($i = 0; $i -lt $prefix; $i++) {
        $mask = $mask -bor (1 -shl (31 - $i))
    }
    $bytes = [BitConverter]::GetBytes([UInt32]$mask)
    return ($bytes[3], $bytes[2], $bytes[1], $bytes[0] -join ".")
}


# ----------------------------------------------------------------------
# 7. Apply the network configuration
# ----------------------------------------------------------------------
foreach ($nicKey in $renameOrder) {

    $entry = $ethernets[$nicKey]

    if (-not $entry["match"]) { continue }

    $targetMac = Normalize-Mac $entry["match"]["macaddress"]
    $nic = Get-NetAdapter | Where-Object {
        Normalize-Mac $_.MacAddress -eq $targetMac
    }

    if (-not $nic) {
        Write-Error "[Cycle] No NIC found for MAC $targetMac"
        continue
    }

    $nicName = $nic.Name
    $newName = $entry["set-name"]

    # Rename NIC safely
    if ($newName -and $newName.Trim() -ne "") {
        $exists = Get-NetAdapter -Name $newName -ErrorAction SilentlyContinue
        if ($exists) {
            Write-Host "[Cycle] Skipping rename: '$newName' already exists"
        } else {
            Rename-NetAdapter -Name $nicName -NewName $newName -ErrorAction Stop
        }
        $nicName = $newName.Trim()
    }

    Write-Host "[Cycle] Configuring NIC $nicName (MAC $targetMac)"

    $quoted = '"' + $nicName + '"'

    # Reset existing config
    netsh interface ip   set address name=$quoted source=dhcp
    netsh interface ipv6 reset | Out-Null

    # ---------------------- IP addresses ----------------------
    foreach ($addr in $entry["addresses"]) {
        $parts  = $addr -split "/"
        $ip     = $parts[0]
        $prefix = [int]$parts[1]

        if ($ip -like "*:*") {
            Write-Host "  + IPv6: $ip/$prefix"
            netsh interface ipv6 add address $quoted $ip/$prefix
        }
        else {
            $mask = PrefixToMask $prefix
            Write-Host "  + IPv4: $ip/$prefix (netmask $mask)"
            netsh interface ip add address $quoted $ip $mask
        }
    }

    # ---------------------- Routes ----------------------------
    foreach ($r in $entry["routes"]) {
        $to     = $r["to"]
        $via    = $r["via"]
        $metric = $r["metric"]

        if ($to -like "*:*") {
            $gateway = ($via -eq "::0") ? "" : $via
            Write-Host "  + IPv6 route: $to via $gateway metric=$metric"
            netsh interface ipv6 add route $to $quoted $gateway metric=$metric
        }
        else {
            $gateway = ($via -eq "0.0.0.0") ? "" : $via
            Write-Host "  + IPv4 route: $to via $gateway metric=$metric"
            netsh interface ip add route $to $quoted $gateway metric=$metric
        }
    }

    # ---------------------- DNS ------------------------------
    if ($entry["nameservers"] -and $entry["nameservers"]["addresses"]) {
        $dnsList = $entry["nameservers"]["addresses"]
        Write-Host "  + DNS: $($dnsList -join ", ")"

        netsh interface ip set dns name=$quoted static $dnsList[0] primary
        for ($i = 1; $i -lt $dnsList.Count; $i++) {
            netsh interface ip add dns name=$quoted $dnsList[$i] index=($i + 1)
        }
    }

    # ---------------------- MTU ------------------------------
    if ($entry["mtu"]) {
        Write-Host "  + MTU = $($entry["mtu"])"
        netsh interface ipv4 set subinterface $quoted mtu=$($entry["mtu"]) store=persistent
    }

    Write-Host "[Cycle] Finished NIC $nicName"
}

Write-Host "[Cycle] Network configuration applied successfully."
