# ZeroTraceFS

ZeroTraceFS is a self-destructing encrypted file system implemented fully in R.
It provides a virtual vault where files in mount/ are synchronized into encrypted storage in data/container.rds, then automatically destroyed when configured triggers fire.

## Highlights

- AES-256-CBC encryption for file payloads
- PBKDF2-HMAC-SHA256 key derivation (10,000 iterations)
- Duress password and failed-auth lockout destruction
- Per-file and global self-destruct triggers
- Secure wipe engine (3 random overwrite passes + 1 zero pass)
- Encrypted state persistence across sessions
- Interactive CLI commands in main.R

## Prerequisites

- R 4.0+
- VS Code with R extension

## Installation and Startup

1. Clone or extract the project into a folder named ZeroTraceFS.
2. Open the folder in VS Code.
3. Start an R terminal in VS Code.
4. Run:

```r
source("main.R")
```

Control mode behavior:

- Explorer mode is default (non-blocking), optimized for File Explorer and click controls.
- Optional terminal command mode can be enabled by setting environment variable before launch:

```powershell
$env:ZTFS_CONTROL_MODE = "terminal"
```

On first run, ZeroTraceFS installs missing packages automatically:

- R6
- openssl
- digest
- jsonlite
- fs
- later
- cli
- crayon

## Runtime Behavior

### First Run

1. Installs packages and initializes mount/ and data/.
2. Prompts to create a new vault.
3. Captures master password and duress password.
4. Captures dead man's switch interval and global vault TTL.
5. Saves initial encrypted container state to data/container.rds.
6. Starts sync + command loop.

### Subsequent Runs

1. Loads container from data/container.rds.
2. Prompts for password.
3. Master password unlocks vault and populates mount/.
4. Duress password triggers full destruction and exits with Vault is empty.
5. Failed attempts are tracked; lockout wipes vault.

## Commands

- status
- list
- add <filepath>
- read <filename>
- set-ttl <filename> <minutes>
- set-reads <filename> <max>
- set-deadline <filename> <YYYY-mm-dd HH:MM:SS>
- audit
- export <filename> <dest>
- destroy <filename>
- destroy-all
- lock
- change-password
- quit

## File Explorer Integration (Windows)

ZeroTraceFS can now be controlled from Windows File Explorer while main.R is running.

### Install Explorer Right-Click Menu

Run this once in PowerShell from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\install_explorer_menu.ps1
```

### Use Right-Click Actions

After installation, right-click files or folders and choose ZeroTraceFS actions:

- File right-click:
  - ZeroTraceFS: Import into Vault
  - ZeroTraceFS: Open Securely (Password)
  - ZeroTraceFS: Destroy in Vault
  - ZeroTraceFS: Set TTL
  - ZeroTraceFS: Set Read Limit
  - ZeroTraceFS: Set Deadline
  - ZeroTraceFS: Read Preview
  - ZeroTraceFS: Export from Vault
- Folder right-click or folder background right-click:
  - ZeroTraceFS: Destroy Entire Vault
  - ZeroTraceFS: Lock Vault
  - ZeroTraceFS: Quit Vault
  - ZeroTraceFS: Queue Status Snapshot
  - ZeroTraceFS: Queue List Files
  - ZeroTraceFS: Queue Recent Audit
  - ZeroTraceFS: Open Control Panel

### How It Works

- Explorer actions enqueue JSON commands in .zerotracefs/commands.
- Running main.R consumes these commands on each cycle.
- Results are written to .zerotracefs/processed.
- Keep main.R running in the R terminal for Explorer actions to execute.
- Command launcher checks runtime heartbeat and shows result dialogs (including read preview snippets).
- Context menu actions run with hidden PowerShell window and use dialog boxes for input when needed.

### Automatic Read Count from File Open (Best Effort)

- When files are opened directly from mount/, ZeroTraceFS attempts to detect access-time changes and increments read_count.
- This depends on OS/filesystem last-access timestamp behavior.
- If your system does not update access time, use Read Preview / read command for guaranteed read_count increments.
- For password prompt + guaranteed read tracking from File Explorer, use ZeroTraceFS: Open Securely (Password).

### Click-Based Control Panel UI (Windows)

Launch the control panel:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\ztfs_control_panel.ps1
```

The panel provides clickable buttons for all core actions:

- Import File
- Destroy File
- Set TTL
- Set Read Limit
- Set Deadline
- Read Preview
- Open Securely (Password)
- Export File
- List Vault Files
- Show Audit
- Refresh Status
- Destroy Entire Vault
- Lock Vault
- Quit Vault

You can also open it from File Explorer folder context menu:

- ZeroTraceFS: Open Control Panel

Runtime status is published to:

- .zerotracefs/status.json

Processed command results are saved as JSON files in:

- .zerotracefs/processed

### Remove Explorer Menu

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\uninstall_explorer_menu.ps1
```

## Security Model

- Plaintext working files exist only in mount/ during active session.
- No plaintext is stored in data/.
- Encrypted payloads and metadata are stored in data/container.rds.
- Every encryption uses a fresh IV.
- Per-file keys are derived from master password + unique salt.
- On destructive events, files are overwritten before deletion.
- On quit/lock, mount/ is wiped.

## Seven Destruction Triggers

1. Per-file TTL
   Example: set-ttl secret.txt 2
   Behavior: secret.txt is destroyed after 2 minutes.

2. Read limit
   Example: set-reads api.txt 2
   Behavior: api.txt is destroyed after allowed reads are exceeded.

3. Date deadline
   Example: set-deadline report.txt 2026-12-31 23:59:59
   Behavior: report.txt is destroyed when deadline time is reached.

4. Global vault TTL
   Configured at startup.
   Behavior: entire vault is destroyed when session lifetime exceeds global limit.

5. Failed authentication lockout
   Behavior: repeated failed logins trigger full vault destruction.

6. Duress password
   Behavior: entering duress password triggers full vault destruction immediately.

7. Dead man's switch
   Configured at startup.
   Behavior: stale heartbeat condition triggers full vault destruction.

## Architecture Diagram (ASCII)

```text
+---------------------------------------------------------------+
|                        ZeroTraceFS CLI                        |
|                     (main.R + R/ui.R)                         |
+------------------------------+--------------------------------+
                               |
                               v
+---------------------------------------------------------------+
|                 Core Orchestration and Policy                 |
|  AuthManager | TriggerEngine | SyncEngine | AuditLogger       |
+------------------------------+--------------------------------+
                               |
                               v
+---------------------------------------------------------------+
|                 Cryptography and Persistence Layer            |
| EncryptionEngine | KeyDerivation | VirtualFileSystem          |
| ContainerManager (data/container.rds) | SecureWiper           |
+------------------------------+--------------------------------+
                               |
                               v
+---------------------------------------------------------------+
| Local Filesystem: mount/ plaintext workspace, data/ encrypted |
+---------------------------------------------------------------+
```

## Use Cases

- Healthcare: disposable patient extracts and temporary records
- Research: controlled lifespan for sensitive datasets
- Finance: ephemeral credentials, reports, and exports
- Security teams: incident artifacts with automatic expiration
- Development: temporary secret files and local key material
- Compliance: policy-driven data retention and destruction

## Running Tests

```r
source("tests/run_all_tests.R")
```

## Running Demo Scenario

```r
source("demo/demo_scenario.R")
```

## Limitations and Disclaimers

- This project runs at user level and does not provide kernel-level filesystem guarantees.
- File recovery resistance depends on OS, filesystem, and hardware behavior.
- Dead man's switch timing in a single-threaded terminal loop is cooperative, not hard real-time.
- Do not treat this as certified secure deletion software for regulated destruction without independent validation.
- Keep backups of non-disposable data outside ZeroTraceFS.
