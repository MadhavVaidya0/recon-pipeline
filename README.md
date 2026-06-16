# 🔍 ReconPipeline

An automated external network reconnaissance pipeline for authorized penetration testing engagements. Chains industry-standard open-source tools into a single command, producing structured, timestamped output for every run.

> ⚠️ **Legal Disclaimer:** This tool is intended for use only on systems and domains you own or have explicit written authorization to test. Unauthorized use against systems you do not have permission to test is illegal and unethical. The author is not responsible for misuse.

---

## 📌 Pipeline Flow

```
Target Domain
     │
     ▼
Subfinder          →  subdomains.txt
     │
     ▼
dnsx               →  resolved.txt
     │
     ▼
httpx              →  live_hosts.txt
                   →  technologies.txt
     │
     ▼
Nmap               →  ports.txt / ports.xml / ports.gnmap
                   →  service_versions.txt
     │
     ▼
Katana             →  crawl_urls.txt
     │
     ▼
Summary            →  summary.txt + pipeline.log
```

---

## 🛠️ Tools Used

| Tool | Purpose | Source |
|------|---------|--------|
| [Subfinder](https://github.com/projectdiscovery/subfinder) | Passive subdomain enumeration | ProjectDiscovery |
| [dnsx](https://github.com/projectdiscovery/dnsx) | DNS resolution & record lookup | ProjectDiscovery |
| [httpx](https://github.com/projectdiscovery/httpx) | HTTP probing & tech fingerprinting | ProjectDiscovery |
| [Nmap](https://nmap.org) | Port scanning & service version detection | Nmap Project |
| [Katana](https://github.com/projectdiscovery/katana) | Web crawling & URL discovery | ProjectDiscovery |

---

## ⚙️ Installation

### Quick install (Ubuntu / Kali / macOS)

```bash
git clone https://github.com/<your-username>/recon-pipeline.git
cd recon-pipeline
chmod +x install.sh recon_pipeline.sh
./install.sh
```

The installer will:
- Detect your OS (Ubuntu, Debian, Kali, macOS)
- Install Go if not present
- Install all ProjectDiscovery tools via `go install`
- Install Nmap via apt / brew
- Add `~/go/bin` to your PATH

### Manual installation

```bash
# Go tools
go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
go install github.com/projectdiscovery/httpx/cmd/httpx@latest
go install github.com/projectdiscovery/katana/cmd/katana@latest

# Nmap
sudo apt install nmap        # Debian/Ubuntu/Kali
brew install nmap            # macOS

# Add Go bin to PATH
echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc && source ~/.bashrc
```

### Requirements

- Linux (Ubuntu 20.04+, Kali 2022+) or macOS
- Go 1.21+
- Bash 4.0+
- Root/sudo access (for Nmap SYN scans)

---

## 🚀 Usage

```bash
./recon_pipeline.sh -d <domain> [options]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-d, --domain` | Target domain **(required)** | — |
| `-o, --output` | Output directory | `./recon_<domain>_<timestamp>` |
| `-t, --threads` | Concurrency for tools | `50` |
| `--skip-nmap` | Skip Nmap stage (faster runs) | `false` |
| `-h, --help` | Show help | — |

### Examples

```bash
# Basic run — auto-timestamped output folder
./recon_pipeline.sh -d example.com

# Custom output directory
./recon_pipeline.sh -d example.com -o ./engagements/example_com

# Fast run without Nmap
./recon_pipeline.sh -d example.com --skip-nmap

# High thread count for faster enumeration
./recon_pipeline.sh -d example.com -t 100
```

---

## 📂 Output Structure

Every run creates a timestamped directory:

```
recon_example.com_20260616_110044/
├── subdomains.txt        # All discovered subdomains (Subfinder)
├── resolved.txt          # DNS-resolved hosts with IPs (dnsx)
├── live_hosts.txt        # HTTP-alive hosts with status, title, tech (httpx)
├── technologies.txt      # Unique technologies fingerprinted (httpx)
├── nmap_targets.txt      # Hosts fed to Nmap
├── ports.txt             # Nmap normal output
├── ports.xml             # Nmap XML output (importable to Metasploit/Nessus)
├── ports.gnmap           # Nmap grepable output
├── service_versions.txt  # Parsed service/version table
├── crawl_urls.txt        # All crawled URLs (Katana)
├── summary.txt           # Run summary with counts
└── pipeline.log          # Full pipeline log
```

### Sample `service_versions.txt`

```
HOST                                          PORT    PROTO        SERVICE / VERSION
──────────────────────────────────────────────────────────────────────────────────────
analytics.example.com                         80      tcp          nginx 1.24.0 (Ubuntu)
analytics.example.com                         443     tcp          nginx 1.24.0 (Ubuntu)
mdm.example.com                               3000    tcp          Jetty 9.4.x
```

---

## 🔎 What Each Stage Does

### Stage 1 — Subfinder (Subdomain Enumeration)
Queries passive sources (certificate transparency logs, DNS datasets, APIs) to enumerate subdomains without sending traffic to the target.

### Stage 2 — dnsx (DNS Resolution)
Resolves discovered subdomains against public resolvers, filtering out dead/non-existent hosts and returning live A/CNAME records with IPs.

### Stage 3 — httpx (HTTP Probing)
Probes resolved hosts over HTTP/HTTPS, detecting: live web services, HTTP status codes, page titles, technology stack (via Wappalyzer signatures), redirect chains.

### Stage 4 — Nmap (Port & Service Scanning)
Scans live hosts for open ports with:
- `-sV --version-intensity 8` — aggressive service version detection
- `-sC` — default NSE scripts (banner grab, SSL cert info, SSH keys, HTTP headers)
- Output in three formats: normal, XML, grepable

### Stage 5 — Katana (Web Crawling)
Crawls all live HTTP hosts to discover endpoints, JS files, API paths, and linked resources up to depth 3.

---

## 📋 Sample Summary Output

```
========================================
  Recon Summary — example.com
  Generated: Mon Jun 16 11:05:32 2026
========================================

[Subdomains]      44
[Resolved]        58
[Live Hosts]      22
[Technologies]    50 unique
[Open Ports]      87
[Crawled URLs]    192

[Output Dir]      ./recon_example.com_20260616_110044
[Log]             ./recon_example.com_20260616_110044/pipeline.log
```

---

## 🧠 Tips for Effective Use

- **Don't use `-o`** unless you have a specific reason — the auto-timestamped folder ensures no two runs overwrite each other.
- **Cloudflare-protected targets:** Nmap will scan the Cloudflare edge, not the origin. Cross-reference with Shodan/Censys to find origin IPs.
- **Post-pipeline steps to consider:**
  - Feed `crawl_urls.txt` into `nuclei` for vulnerability scanning
  - Run `tlsx` on `live_hosts.txt` for TLS/cert analysis and SAN enumeration
  - Run `gau` or `waybackurls` for historical URL discovery
  - Run `gowitness` on `live_hosts.txt` for screenshots

---

## 📁 Repository Structure

```
recon-pipeline/
├── recon_pipeline.sh     # Main pipeline script
├── install.sh            # Dependency installer
└── README.md             # This file
```

---

## 👤 Author

**Madhav Vaidya**
Information Security | VAPT | Cloud Security

---

## 📄 License

This project is licensed under the MIT License — use freely for authorized security testing.
