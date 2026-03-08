<div align="center">

# ðŸ” ZeroTraceFS

### Self-Destructing Encrypted File System in R

*Encrypt â†’ Use â†’ Destroy â†’ Automatically*

![R](https://img.shields.io/badge/R-4.0%2B-276DC3?style=flat-square&logo=r&logoColor=white)
![AES-256](https://img.shields.io/badge/Encryption-AES--256--CBC-red?style=flat-square)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey?style=flat-square)
![License](https://img.shields.io/badge/License-Proprietary-black?style=flat-square)

> An **in-memory encrypted virtual file system** that automatically destroys sensitive data when it's no longer needed â€” no manual cleanup, no recoverable traces.

</div>

---

## What is ZeroTraceFS?

Traditional file systems have a fundamental flaw: **deleted files aren't really deleted.** Data lingers on disk, accumulates after its purpose ends, and can be recovered with forensic tools long after you thought it was gone.

ZeroTraceFS solves this at the root. Every file is encrypted from the moment it's written, lives only in RAM, and is automatically, irreversibly destroyed the moment any configured condition is triggered. No cloud. No admin rights. No manual cleanup.

---

## Features at a Glance

| | Feature | Detail |
|---|---|---|
| ðŸ”’ | **AES-256-CBC Encryption** | Every file encrypted before storage, unique IV per write |
| ðŸ§  | **In-Memory Storage** | All data lives in RAM â€” nothing touches disk |
| ðŸ’£ | **7 Self-Destruct Triggers** | Time, access count, deadline, failed auth, duress, inactivity |
| ðŸ§¹ | **Secure 4-Pass Wipe** | Cryptographic overwrite makes recovery virtually impossible |
| ðŸ”‘ | **PBKDF2 Key Derivation** | 100,000 iterations â€” brute-force resistant |
| ðŸ“‹ | **Full Audit Logging** | Tamper-evident log of every file operation |
| ðŸ“¦ | **Persistent Containers** | Optional encrypted save/load for cross-session use |
| ðŸ’» | **Cross-Platform** | Windows Â· macOS Â· Linux, no admin rights needed |

---

## The 7 Self-Destruct Triggers

Any trigger firing causes an **immediate, irrecoverable** secure wipe.

| # | Trigger | Fires Whenâ€¦ | Example Use Case |
|---|---|---|---|
| 1 | **Per-File TTL** | File age exceeds a set duration | Temp password expires after 10 min |
| 2 | **Read Limit** | File has been read N times | One-time password consumed |
| 3 | **Date Deadline** | A specific date/time is reached | Research data locked to project end |
| 4 | **Global TTL** | The whole container ages out | Entire session wiped at shutdown |
| 5 | **Failed Authentication** | Too many wrong password attempts | Brute-force lockout |
| 6 | **Duress Password** | A special "panic" password is entered | Coercion protection â€” wipes instead of unlocks |
| 7 | **Dead Man's Switch** | Owner fails to check in on schedule | Unattended data auto-destructs |

---

## vs. Existing Tools

| Feature | VeraCrypt | Signal | AWS S3 | encryptr | **ZeroTraceFS** |
|---|:---:|:---:|:---:|:---:|:---:|
| AES-256 encryption | âœ“ | âœ“ | âœ“ | âœ“ | âœ“ |
| Auto time-based destruction | âœ— | âœ“ | âœ“ | âœ— | âœ“ |
| Read count limits | âœ— | âœ— | âœ— | âœ— | âœ“ |
| Duress password | âœ— | âœ— | âœ— | âœ— | âœ“ |
| Dead man's switch | âœ— | âœ— | âœ— | âœ— | âœ“ |
| Secure memory wipe | âœ— | âœ— | âœ— | âœ— | âœ“ |
| R-native | âœ— | âœ— | âœ— | âœ“ | âœ“ |
| Offline / no cloud | âœ“ | âœ“ | âœ— | âœ“ | âœ“ |
| No admin rights | âœ— | âœ“ | âœ“ | âœ“ | âœ“ |

---

## Architecture

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                User API Layer                â”‚
â”‚    write()  read()  delete()  destroy()      â”‚
â”‚    list_files()  save_container()            â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                     â”‚
       â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
       â–¼             â–¼             â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â” â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚  Auth      â”‚ â”‚  Crypto   â”‚ â”‚  Destruction   â”‚
â”‚  Engine    â”‚ â”‚  Engine   â”‚ â”‚  Engine        â”‚
â”‚            â”‚ â”‚           â”‚ â”‚                â”‚
â”‚ PBKDF2     â”‚ â”‚ AES-256   â”‚ â”‚ 7 triggers     â”‚
â”‚ Salt mgmt  â”‚ â”‚ IV gen    â”‚ â”‚ Policy check   â”‚
â”‚ Pasword    â”‚ â”‚ Serialize â”‚ â”‚ Secure wipe    â”‚
â”‚ verify     â”‚ â”‚           â”‚ â”‚                â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                     â”‚
       â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â–¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
       â”‚  Encrypted File Tree (RAM)â”‚
       â”‚  ciphertext Â· IV Â· hash   â”‚
       â”‚  read count Â· expiry      â”‚
       â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                     â”‚
       â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â–¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
       â”‚  Audit Logger Â· Container â”‚
       â”‚  I/O Â· Integrity Checker  â”‚
       â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

---

## Secure Wipe Protocol

Standard deletion only removes a file pointer â€” the bytes stay in memory until overwritten. ZeroTraceFS applies a **4-pass cryptographic wipe** before releasing any memory:

```
Pass 1  â†’  Overwrite with random bytes
Pass 2  â†’  Overwrite with random bytes
Pass 3  â†’  Overwrite with random bytes
Pass 4  â†’  Overwrite with zeros
          â†“
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
| ðŸ¥ Healthcare | Auto-delete patient records after processing | TTL + Deadline |
| ðŸ”¬ Research | Secure datasets that expire with the project | Dead man's switch + Deadline |
| ðŸ’° Finance | Self-destructing API keys and session tokens | Read limit + TTL |
| ðŸ›¡ï¸ Security Ops | Coercion-proof credential storage | Duress password + Failed auth |
| ðŸ‘¨â€ðŸ’» Development | Ephemeral test credentials and config | Global TTL |
| âš–ï¸ Compliance | GDPR "right to be forgotten" with audit trail | All triggers + Audit log |

---

## Tech Stack

| Component | Technology |
|---|---|
| Language | R 4.0+ |
| OOP | R6 classes |
| Encryption | `openssl` â€” AES-256-CBC, PBKDF2 |
| Hashing | `digest` â€” SHA-256 |
| Testing | `testthat` |

**Minimum requirements:** 512 MB RAM Â· No internet Â· No admin rights

---

## License

This project is **proprietary and not open source.** All rights reserved.
Unauthorised copying, distribution, or modification is strictly prohibited.

---

<div align="center">

*ZeroTraceFS — because some data should never be found.*

</div>
