# mac-mdm-bypass

A hardened, self-contained Bash script that removes Automated Device Enrollment (DEP/MDM) enrollment hooks from a Mac by creating a local administrator account and blocking Apple's enrollment callbacks — run entirely from **macOS Recovery**.

> **Use case:** refurbishers, IT admins re-provisioning decommissioned hardware, labs, and authorized device administration.

---

## ⚠️ Disclaimer

This tool is intended for **authorized device administration only** — devices you own, or are explicitly authorized to manage (e.g., refurbished units, decommissioned corporate hardware, lab machines).

It is **not** a tool for circumventing ownership of devices you don't control, and it does not bypass Activation Lock (Find My). Use responsibly and in accordance with your local laws and organizational policies.

---

## What it does

1. **Detects and mounts** the macOS System and Data volumes (APFS role-based detection with mounted-volume fallback).
2. **Creates a local administrator account** directly in the Data volume's Directory Services node (`dslocal`), with a free UID (501–599), home directory, and admin group membership.
3. **Blocks Apple's MDM enrollment domains** in `/etc/hosts` (with automatic backup of the original file).
4. **Clears cloud enrollment records** and marks Setup Assistant as complete (`.AppleSetupDone`, cloudConfig markers).

After a reboot, the Mac boots to a normal login screen with your local admin — no MDM enrollment screen.

---

## Requirements

- macOS Recovery mode (Intel: `Cmd+R` at boot · Apple Silicon: hold power button until *Loading startup options*, then select *Options*)
- The Mac must have macOS installed
- The script runs as root (Recovery gives you root automatically)

Tested against macOS Monterey through Sequoia. Report successes/failures per version in Issues.

---

## Usage

Download or clone, then from the Recovery terminal:

```bash
# Defaults (user: Apple / password: 1234), with one y/N confirmation
./mdm-bypass.sh

# Fully unattended — no prompts at all
./mdm-bypass.sh -y

# Custom credentials
./mdm-bypass.sh -y -u techadmin -f "Tech Admin" -p 'Str0ngPass!'

# Block extra domains (comma-separated)
./mdm-bypass.sh -y -d "domain"
```

Typical one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/Hamza-Boulila/mac-mdm-bypass/main/mdm-bypass.sh -o mdm-bypass.sh && chmod +x mdm-bypass.sh && ./mdm-bypass.sh -y && reboot
```

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-u` | Username | `Apple` |
| `-f` | Full name | `Apple` |
| `-p` | Password (min 4 chars) | `1234` |
| `-d` | Extra domains to block, comma-separated | *(built-in list only)* |
| `-y` | Skip confirmation prompt (unattended) | off |
| `-h` | Show help | — |

---

## Built-in blocked domains

Add more with `-d "domain1,domain2"`.

---

## Safety & design notes

- **Idempotent** — safe to re-run; duplicate hosts entries are prevented, existing users auto-resolved (`Apple` → `Apple1`…).
- **Hosts backup** — the original `/etc/hosts` is saved to `/etc/hosts.bak-mdm` before any modification. Restore with:
  ```bash
  sudo cp /etc/hosts.bak-mdm /etc/hosts
  ```
- **Fail-fast** — critical steps (user record, password, admin group) abort with clear errors; cosmetic failures warn and continue.
- **Free-UID search** — picks the first available UID in 501–599 instead of blindly using 501.
- **Home directory ownership** — the new user's home is `chown`-ed to the new UID (avoids FileVault/desktop issues).
- **Exit codes** — `0` on success, `1` on any critical failure, so you can chain commands: `./mdm-bypass.sh -y && reboot`.

---

## Undoing the bypass

1. Restore the hosts file: `sudo cp /etc/hosts.bak-mdm /etc/hosts`
2. Delete the local user: `sudo dscl . -delete /Users/username`
3. Remove markers:
   ```bash
   sudo rm /var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled
   sudo rm /var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound
   sudo rm /private/var/db/.AppleSetupDone
   ```
4. Re-enroll via your MDM solution (or `sudo profiles renew -type enrollment`).

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Must run as root" | You're not in Recovery — reboot into Recovery mode. |
| "Data volume not found" | The Data volume may be FileVault-encrypted and locked. Unlock it in Recovery first (Disk Utility → Mount), or the Startup Disk password prompt. |
| "Directory Services node missing" | macOS isn't installed on the disk, or you mounted the wrong volume. |
| Login loop after reboot | Log in once at the console (or wait for Setup Assistant), then delete/recreate the user from an admin session. |
| Still gets MDM prompt after reboot | Your org may use a network-layer DEP check — ensure the blocked domains resolve to `0.0.0.0`: `dscacheutil -q host -a name deviceenrollment.apple.com` |

---

## FAQ

**Does this bypass Activation Lock / iCloud lock?**
No. This is not an Activation Lock tool and doesn't touch Find My.

**Does it survive macOS updates?**
The local user does. The hosts entries and markers may need re-application after major upgrades — simply re-run the script.

**Why Recovery mode?**
The Data volume's user database (`dslocal`) is only writable from Recovery without additional SIP-related steps, and Setup Assistant runs immediately after Recovery-based changes.

---

## Contributing

PRs welcome — especially macOS version compatibility reports and additional blocked domains used by common MDM vendors.

## License

MIT — see [LICENSE](LICENSE).
