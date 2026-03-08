<div align="center">

# ZeroTraceFS

### Self-Destructing Encrypted File System in R

**`Encrypt` &rarr; `Use` &rarr; `Destroy` &rarr; `Automatically`**

![R](https://img.shields.io/badge/R-4.0%2B-276DC3?style=flat-square&logo=r&logoColor=white)
![AES-256](https://img.shields.io/badge/Encryption-AES--256--CBC-red?style=flat-square)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey?style=flat-square)
![License](https://img.shields.io/badge/License-Proprietary-black?style=flat-square)

> An **in-memory encrypted virtual file system** that automatically destroys sensitive data when it's no longer needed &mdash; no manual cleanup, no recoverable traces.

</div>

---

## What is ZeroTraceFS?

Traditional file systems have a fundamental flaw: **deleted files aren't really deleted.** Data lingers on disk, accumulates after its purpose ends, and can be recovered with forensic tools long after you thought it was gone.

ZeroTraceFS solves this at the root. Every file is encrypted from the moment it's written, lives only in RAM, and is automatically, irreversibly destroyed the moment any configured condition is triggered. No cloud. No admin rights. No manual cleanup.

---

## Features at a Glance

| Feature | Detail |
|---|---|
| **AES-256-CBC Encryption** | Every file encrypted before storage, unique IV per write |
| **In-Memory Storage** | All data lives in RAM &mdash; nothing touches disk |
| **7 Self-Destruct Triggers** | Time, access count, deadline, failed auth, duress, inactivity |
| **Secure 4-Pass Wipe** | Cryptographic overwrite makes recovery virtually impossible |
| **PBKDF2 Key Derivation** | 100,000 iterations &mdash; brute-force resistant |
| **Full Audit Logging** | Tamper-evident log of every file operation |
| **Persistent Containers** | Optional encrypted save/load for cross-session use |
| **Cross-Platform** | Windows &middot; macOS &middot; Linux, no admin rights needed |

---

## The 7 Self-Destruct Triggers

Any trigger firing causes an **immediate, irrecoverable** secure wipe.

| # | Trigger | Fires When... | Example Use Case |
|---|---|---|---|
| 1 | **Per-File TTL** | File age exceeds a set duration | Temp password expires after 10 min |
| 2 | **Read Limit** | File has been read N times | One-time password consumed |
| 3 | **Date Deadline** | A specific date/time is reached | Research data locked to project end |
| 4 | **Global TTL** | The whole container ages out | Entire session wiped at shutdown |
| 5 | **Failed Authentication** | Too many wrong password attempts | Brute-force lockout |
| 6 | **Duress Password** | A special "panic" password is entered | Coercion protection &mdash; wipes instead of unlocks |
| 7 | **Dead Man's Switch** | Owner fails to check in on schedule | Unattended data auto-destructs |

---

## vs. Existing Tools

| Feature | VeraCrypt | Signal | AWS S3 | encryptr | **ZeroTraceFS** |
|---|:---:|:---:|:---:|:---:|:---:|
| AES-256 encryption | Yes | Yes | Yes | Yes | Yes |
| Auto time-based destruction | No | Yes | Yes | No | **Yes** |
| Read count limits | No | No | No | No | **Yes** |
| Duress password | No | No | No | No | **Yes** |
| Dead man's switch | No | No | No | No | **Yes** |
| Secure memory wipe | No | No | No | No | **Yes** |
| R-native | No | No | No | Yes | **Yes** |
| Offline / no cloud | Yes | Yes | No | Yes | **Yes** |
| No admin rights | No | Yes | Yes | Yes | **Yes** |

---

## Architecture

```
+----------------------------------------------+
|               User API Layer                 |
|   write()  read()  delete()  destroy()       |
|   list_files()  save_container()             |
+--------------------+-------------------------+
                     |
       +-------------+-------------+
       |             |             |
+------------+ +-----------+ +----------------+
| Auth       | | Crypto    | | Destruction    |
| Engine     | | Engine    | | Engine         |
|            | |           | |                |
| PBKDF2     | | AES-256   | | 7 triggers     |
| Salt mgmt  | | IV gen    | | Policy check   |
| Password   | | Serialize | | Secure wipe    |
| verify     | |           | |                |
+------------+ +-----------+ +----------------+
                     |
       +-------------v-------------+
       |  Encrypted File Tree (RAM)|
       |  ciphertext - IV - hash   |
       |  read count - expiry      |
       +-------------+-------------+
                     |
       +-------------v-------------+
       |  Audit Logger - Container |
       |  I/O - Integrity Checker  |
       +---------------------------+
```

---

## Secure Wipe Protocol

Standard deletion only removes a file pointer &mdash; the bytes stay in memory until overwritten. ZeroTraceFS applies a **4-pass cryptographic wipe** before releasing any memory:

```
Pass 1  ->  Overwrite with random bytes
Pass 2  ->  Overwrite with random bytes
Pass 3  ->  Overwrite with random bytes
Pass 4  ->  Overwrite with zeros
          |
          v
    Destroy encryption key
    Erase all metadata
    Deallocate memory
```

---

## Quick Start

**Install dependencies:**

```r
install.packages(c("R6", "openssl", "digest", "testthat"))
```

**Basic usage:**

```r
# Create an encrypted file system
fs <- SDEFS$new(password = "your-strong-password", ttl_seconds = 3600)

# Write a file (encrypted immediately in RAM)
fs$write("secrets.txt", "API_KEY=abc123xyz")

# Read it back (decrypted on-the-fly, never touches disk)
fs$read("secrets.txt")

# Manually destroy all data
fs$destroy()
```

---

## Use Cases

| Domain | Use Case | Triggers |
|---|---|---|
| Healthcare | Auto-delete patient records after processing | TTL + Deadline |
| Research | Secure datasets that expire with the project | Dead man's switch + Deadline |
| Finance | Self-destructing API keys and session tokens | Read limit + TTL |
| Security Ops | Coercion-proof credential storage | Duress password + Failed auth |
| Development | Ephemeral test credentials and config | Global TTL |
| Compliance | GDPR "right to be forgotten" with audit trail | All triggers + Audit log |

---

## Tech Stack

| Component | Technology |
|---|---|
| Language | R 4.0+ |
| OOP | R6 classes |
| Encryption | `openssl` &mdash; AES-256-CBC, PBKDF2 |
| Hashing | `digest` &mdash; SHA-256 |
| Testing | `testthat` |

**Minimum requirements:** 512 MB RAM &middot; No internet &middot; No admin rights

---

## License

This project is **proprietary and not open source.** All rights reserved.  
Unauthorised copying, distribution, or modification is strictly prohibited.

---

<div align="center">

*ZeroTraceFS &mdash; because some data should never be found.*

</div>
