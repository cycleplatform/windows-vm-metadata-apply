# Cycle Windows VM Netconf Apply Script

<a href="https://cycle.io">
<picture class="red">
  <source media="(prefers-color-scheme: dark)" srcset="https://static.cycle.io/icons/logo/logo-white.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://static.cycle.io/icons/logo/cycle-logo-fullcolor.svg">
  <img alt="cycle" width="300px" src="https://static.cycle.io/icons/logo/cycle-logo-fullcolor.svg">
</picture>
</a>

A PowerShell script for applying a Linux-style `network-config` cloud-init file to a Windows VM.

This script is designed for environments where Windows VMs are provisioned using cloud-init–style metadata, such as Cycle.io. It reads the `network-config` file from the VM's config-drive and applies all network settings—IP addresses, routes, DNS, MTU, and NIC renaming—directly to Windows networking.


## Running Inside a Cycle Windows VM

Cycle automatically attaches a config-drive to every VM during provisioning. This drive contains metadata including:

- `user-data`
- `meta-data`
- `network-config`

To run the script inside the VM:

### 1. Use an attachment to mount the ISO containing this script into the VM.

It will most likely be available under the `F:\` drive, but may be different for you.

### 2. Connect to the VM using VNC in the Cycle Portal

Open the VM in the Cycle Portal and use the built-in VNC console to connect and log in.

### 3. Open PowerShell as Administrator

Right-click Start → Windows PowerShell (Admin).

### 4. Run the script

```powershell
F:\netconf-apply.ps1
```

Expected output example:

```
[Cycle] Applying network configuration...
[Cycle] Found network-config on D:
[Cycle] Configuring NIC eth0 (MAC 92:6b:89:cf:ca:fe)
...
[Cycle] Network configuration applied successfully.
```

## How the Script Works

Once executed, the script performs the following actions inside the Windows VM:

### 1. **Locate the config-drive**

Cycle mounts a config-drive at boot, typically assigned to `D:\`.
The script automatically detects this drive and verifies that `D:\network-config` exists.

### 2. **Parse the Linux-style `network-config` file**

Windows does not support cloud-init natively, so the script includes a lightweight PowerShell YAML parser.
It extracts:

- NIC match rules (MAC addresses)
- Desired NIC names (`set-name`)
- IP addresses (IPv4 + IPv6)
- Routes
- DNS servers
- MTU values

### 3. **Match Windows NICs by MAC**

Each network adapter in the VM is located using its MAC address.
This ensures the correct settings apply to the correct NIC, regardless of naming differences like `Ethernet` or `Ethernet 2`.

### 4. **Rename NICs safely**

If the YAML specifies NIC names (e.g., `eth0`, `eth1`), the script renames Windows adapters.

### 5. **Apply full network configuration**

For each interface, the script applies:

- IPv4 using correctly computed subnet masks
- IPv6 using prefix notation
- Static routes
- DNS server list
- MTU configuration

All changes are applied immediately using `netsh`, without requiring a reboot.

## Troubleshooting

If the network configuration does not apply as expected, here are some steps to diagnose and resolve common issues:

### 1. **Check that the config-drive is mounted**
Verify that Windows can see the config-drive (usually `D:\`):

```powershell
Get-ChildItem D:\
```

You should see:

- network-config
- meta-data
- user-data

### 2. View the parsed YAML

The script prints the network devices read from the YAML config.
Confirm that:

MAC addresses match the actual Windows NICs

set-name values are correct

Addresses, routes, and DNS entries look correct

### 3. Confirm NIC MAC addresses

Check Windows NICs:

```powershell
Get-NetAdapter | Select Name, MacAddress
```

These must match the fields printed in the script.

### 4. Re-run the script

After fixing any issues, re-run:

```powershell
F:\netconf-apply.ps1
```