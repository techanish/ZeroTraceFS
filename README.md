<div align="center">

# ZeroTraceFS

### Self-Destructing Encrypted File System in R

> `Encrypt` &nbsp;&rarr;&nbsp; `Use` &nbsp;&rarr;&nbsp; `Destroy` &nbsp;&rarr;&nbsp; `Automatically`

<br/>

[![R](https://img.shields.io/badge/R-4.0%2B-276DC3?style=flat-square&logo=r&logoColor=white)](https://www.r-project.org/)
[![Encryption](https://img.shields.io/badge/Encryption-AES--256--CBC-CC0000?style=flat-square&logo=letsencrypt&logoColor=white)](https://en.wikipedia.org/wiki/Advanced_Encryption_Standard)
[![PBKDF2](https://img.shields.io/badge/KDF-PBKDF2%20100k%20iter-orange?style=flat-square)](https://en.wikipedia.org/wiki/PBKDF2)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-555555?style=flat-square&logo=linux&logoColor=white)](https://cran.r-project.org/)
[![License](https://img.shields.io/badge/License-Proprietary-black?style=flat-square)](./LICENSE)

<br/>

**An in-memory encrypted virtual file system that automatically destroys sensitive data**
**when it is no longer needed &mdash; no manual cleanup, no recoverable traces.**

<br/>

</div>

---

## What is ZeroTraceFS?

Traditional file systems have a fundamental flaw: **deleted files are never truly deleted.** Data lingers on disk long after its purpose ends and can be recovered with forensic tools hours, days, or even years later.

ZeroTraceFS solves this at the root:

- Every file is **encrypted with AES-256-CBC** the instant it is written
- All data lives **exclusively in RAM** &mdash; nothing is ever written to disk
- Files are **automatically, irreversibly destroyed** the moment any configured condition fires
- Zero cloud dependencies, zero admin rights, zero manual intervention

---

## Features

| Feature | Detail |
|---|---|
| **AES-256-CBC Encryption** | Military-grade cipher, unique IV per file per write |
| **In-Memory Storage** | Data lives only in RAM &mdash; no disk traces possible |
| **7 Self-Destruct Triggers** | Time, read count, deadline, auth failure, duress, inactivity |
| **Secure 4-Pass Wipe** | Cryptographic overwrite &mdash; forensically unrecoverable |
| **PBKDF2 Key Derivation** | 100,000 iterations &mdash; resistant to brute-force attacks |
| **Duress Password** | Wipes data silently when a coercion password is entered |
| **Dead Man's Switch** | Auto-destroys if owner fails to check in on schedule |
| **Full Audit Logging** | Tamper-evident record of every file operation |
| **Persistent Containers** | Optional encrypted save/load for cross-session storage |
| **Cross-Platform** | Windows, macOS, Linux &mdash; no admin rights required |

---

## Quick Start

```r
# Install dependencies
install.packages(c("R6", "openssl", "digest", "testthat"))
```

```r
# Create an encrypted in-memory file system (auto-destroys after 1 hour)
fs <- SDEFS$new(password = "your-strong-password", ttl_seconds = 3600)

# Write an object -- encrypted immediately, stored only in RAM
fs$write("api_key.txt", "sk-abc123xyz", ttl_seconds = 300)

# Read it back -- decrypted on-the-fly, never touches disk
fs$read("api_key.txt")

# List all live files
fs$list_files()

# Manually trigger full secure wipe
fs$destroy()
```

---

## The 7 Self-Destruct Triggers

> Any single trigger firing causes an **immediate, irrecoverable** secure wipe of the affected data.

| # | Trigger | Fires When... | Example |
|:---:|---|---|---|
| 1 | **Per-File TTL** | File age exceeds configured lifetime | Temp credential expires after 5 min |
| 2 | **Read Limit** | File has been read N times | One-time password self-destructs after use |
| 3 | **Date Deadline** | A specific calendar date is reached | Research data expires at project end |
| 4 | **Global TTL** | The whole container ages out | Session wiped automatically at day's end |
| 5 | **Failed Authentication** | N consecutive wrong passwords entered | Brute-force attack triggers total wipe |
| 6 | **Duress Password** | Special "panic" password is entered | Coercion attempt causes silent wipe |
| 7 | **Dead Man's Switch** | Owner misses a scheduled check-in | Unattended server data self-destructs |

---

## Secure Wipe Protocol

Standard deletion only removes a directory pointer &mdash; the raw bytes remain in memory until coincidentally overwritten. ZeroTraceFS uses a **4-pass cryptographic wipe** that makes recovery virtually impossible:

```
[ Pass 1 ]  Write random bytes over all data
[ Pass 2 ]  Write random bytes over all data
[ Pass 3 ]  Write random bytes over all data
[ Pass 4 ]  Write zero  bytes over all data
                    |
                    v
         Destroy encryption key
         Erase all file metadata
         Deallocate memory region
```

---

## Architecture

```
 +-------------------------------------------------+
 |                 User API Layer                  |
 |   write()   read()   delete()   destroy()       |
 |   list_files()   save_container()               |
 +-------------------+-----------------------------+
                     |
       +-------------+-------------+
       |             |             |
 +------------+ +-----------+ +-------------------+
 | Auth       | | Crypto    | | Destruction       |
 | Engine     | | Engine    | | Engine            |
 |            | |           | |                   |
 | PBKDF2     | | AES-256   | | 7 trigger checks  |
 | Salt mgmt  | | CBC       | | Policy enforce    |
 | Password   | | IV gen    | | Secure wipe exec  |
 | verify     | | Serialize | |                   |
 +------------+ +-----------+ +-------------------+
                     |
         +-----------v-----------+
         | Encrypted File Tree   |
         | (stored in RAM only)  |
         |                       |
         | ciphertext  IV  hash  |
         | read-count  expiry    |
         +-----------+-----------+
                     |
         +-----------v-----------+
         | Audit Logger          |
         | Container I/O         |
         | Integrity Checker     |
         +-----------------------+
```

---

## How It Compares

| Feature | VeraCrypt | Signal | AWS S3 | encryptr | **ZeroTraceFS** |
|---|:---:|:---:|:---:|:---:|:---:|
| AES-256 encryption | Yes | Yes | Yes | Yes | **Yes** |
| Auto time-based destruction | No | Yes | Yes | No | **Yes** |
| Read count limits | No | No | No | No | **Yes** |
| Duress password | No | No | No | No | **Yes** |
| Dead man's switch | No | No | No | No | **Yes** |
| Secure memory wipe | No | No | No | No | **Yes** |
| R-native | No | No | No | Yes | **Yes** |
| Offline &mdash; no cloud | Yes | Yes | No | Yes | **Yes** |
| No admin rights required | No | Yes | Yes | Yes | **Yes** |

---

## Use Cases

| Domain | Scenario | Triggers Used |
|---|---|---|
| **Healthcare** | Auto-delete patient records after processing | TTL + Deadline |
| **Research** | Confidential datasets expire with the project | Dead man's switch + Deadline |
| **Finance** | Self-destructing API keys and session tokens | Read limit + TTL |
| **Security Ops** | Coercion-proof credential storage | Duress password + Failed auth |
| **Development** | Ephemeral test credentials and config | Global TTL |
| **Compliance** | GDPR right-to-be-forgotten with full audit trail | All triggers + Audit log |

---

## Tech Stack

| Component | Technology |
|---|---|
| Language | R 4.0+ |
| OOP Framework | R6 classes |
| Encryption | `openssl` &mdash; AES-256-CBC, PBKDF2 key derivation |
| Hashing | `digest` &mdash; SHA-256 integrity verification |
| Testing | `testthat` &mdash; unit and integration tests |

**System requirements:** R 4.0+ &nbsp;|&nbsp; 512 MB RAM &nbsp;|&nbsp; No internet &nbsp;|&nbsp; No admin rights

---

## License

This project is **proprietary software. All rights reserved.**

Unauthorised use, copying, modification, or distribution of this software,
in whole or in part, is strictly prohibited without explicit written permission.

---

<div align="center">

<br/>

**ZeroTraceFS** &nbsp;&mdash;&nbsp; *Because some data should never be found.*

<br/>

[![Encrypt](https://img.shields.io/badge/-Encrypt-1a1a2e?style=flat-square)]()
[![arrow](https://img.shields.io/badge/-%E2%86%92-444444?style=flat-square)]()
[![Use](https://img.shields.io/badge/-Use-16213e?style=flat-square)]()
[![arrow](https://img.shields.io/badge/-%E2%86%92-444444?style=flat-square)]()
[![Destroy](https://img.shields.io/badge/-Destroy-CC0000?style=flat-square)]()
[![arrow](https://img.shields.io/badge/-%E2%86%92-444444?style=flat-square)]()
[![Automatically](https://img.shields.io/badge/-Automatically-0f3460?style=flat-square)]()

<br/>

</div>
