#!/usr/bin/env bash
# =============================================================================
# recon_pipeline.sh — Automated Recon Pipeline
# Flow: Subfinder → dnsx → httpx → Nmap → Katana
#
# Usage:
#   ./recon_pipeline.sh -d <domain> [-o <output_dir>] [-t <threads>] [--skip-nmap]
#
# Dependencies:
#   subfinder, dnsx, httpx, nmap, katana
#   Install via: go install / apt / brew as appropriate
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Defaults ─────────────────────────────────────────────────────────────────
DOMAIN=""
OUTPUT_DIR=""
THREADS=50
SKIP_NMAP=false
SKIP_NUCLEI=false
NMAP_TOP_PORTS=1000
KATANA_DEPTH=3
NUCLEI_SEVERITY="critical,high,medium"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[*]${RESET} $*"; }
success() { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}════════════════════════════════════════${RESET}\n"; }

usage() {
    cat <<EOF
${BOLD}Usage:${RESET}
  $0 -d <domain> [-o <output_dir>] [-t <threads>] [--skip-nmap] [--skip-nuclei] [--severity <levels>]

${BOLD}Options:${RESET}
  -d, --domain      Target domain (required)
  -o, --output      Output directory (default: ./recon_<domain>_<timestamp>)
  -t, --threads     Concurrency for tools (default: 50)
  --skip-nmap       Skip Nmap port scan (faster runs)
  -h, --help        Show this help

${BOLD}Example:${RESET}
  $0 -d example.com -o ./results -t 100
EOF
    exit 0
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)   DOMAIN="$2";     shift 2 ;;
        -o|--output)   OUTPUT_DIR="$2"; shift 2 ;;
        -t|--threads)  THREADS="$2";    shift 2 ;;
        --skip-nmap)    SKIP_NMAP=true;    shift   ;;
        --skip-nuclei)  SKIP_NUCLEI=true;  shift   ;;
        --severity)     NUCLEI_SEVERITY="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) error "Unknown option: $1" ;;
    esac
done

[[ -z "$DOMAIN" ]] && error "Target domain is required. Use -d <domain>"

# ── Setup output dir ──────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="./recon_${DOMAIN}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

LOG_FILE="${OUTPUT_DIR}/pipeline.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Tool paths ────────────────────────────────────────────────────────────────
SUBDOMAINS="${OUTPUT_DIR}/subdomains.txt"
RESOLVED="${OUTPUT_DIR}/resolved.txt"
LIVE_HOSTS="${OUTPUT_DIR}/live_hosts.txt"
TECHNOLOGIES="${OUTPUT_DIR}/technologies.txt"
PORTS="${OUTPUT_DIR}/ports.txt"
CRAWL_URLS="${OUTPUT_DIR}/crawl_urls.txt"
SUMMARY="${OUTPUT_DIR}/summary.txt"
NUCLEI_DIR="${OUTPUT_DIR}/nuclei"
NUCLEI_OUT="${NUCLEI_DIR}/findings.txt"
NUCLEI_JSON="${NUCLEI_DIR}/findings.jsonl"

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
    banner "Checking Dependencies"
    local tools=(subfinder dnsx httpx nmap katana nuclei)
    local missing=()
    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            success "$tool found at $(command -v "$tool")"
        else
            warn "$tool NOT found"
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing tools: ${missing[*]}"
        warn "Skipping steps that require missing tools."
    fi
    echo
}

# ── Stage 1: Subfinder ────────────────────────────────────────────────────────
stage_subfinder() {
    banner "Stage 1 — Subdomain Enumeration (Subfinder)"
    if ! command -v subfinder &>/dev/null; then
        warn "Skipping: subfinder not installed"
        return
    fi

    info "Target: $DOMAIN"
    subfinder \
        -d "$DOMAIN" \
        -silent \
        -t "$THREADS" \
        -o "$SUBDOMAINS"

    local count
    count=$(wc -l < "$SUBDOMAINS" | tr -d ' ')
    success "Found ${count} subdomains → ${SUBDOMAINS}"
}

# ── Stage 2: dnsx ─────────────────────────────────────────────────────────────
stage_dnsx() {
    banner "Stage 2 — DNS Resolution (dnsx)"
    if ! command -v dnsx &>/dev/null; then
        warn "Skipping: dnsx not installed"
        return
    fi
    if [[ ! -s "$SUBDOMAINS" ]]; then
        warn "Skipping: subdomains.txt is empty"
        return
    fi

    dnsx \
        -l "$SUBDOMAINS" \
        -silent \
        -t "$THREADS" \
        -resp \
        -o "$RESOLVED"

    local count
    count=$(wc -l < "$RESOLVED" | tr -d ' ')
    success "Resolved ${count} hosts → ${RESOLVED}"
}

# ── Stage 3: httpx ────────────────────────────────────────────────────────────
stage_httpx() {
    banner "Stage 3 — HTTP Probing (httpx)"
    if ! command -v httpx &>/dev/null; then
        warn "Skipping: httpx not installed"
        return
    fi
    if [[ ! -s "$RESOLVED" ]]; then
        warn "Skipping: resolved.txt is empty"
        return
    fi

    # Extract just the hostnames from dnsx output (first field)
    awk '{print $1}' "$RESOLVED" | \
    httpx \
        -silent \
        -threads "$THREADS" \
        -tech-detect \
        -status-code \
        -title \
        -follow-redirects \
        -o "$LIVE_HOSTS"

    # Separate technology fingerprint lines
    grep -oP '\[.*?\]' "$LIVE_HOSTS" | \
        tr -d '[]' | tr ',' '\n' | sort -u > "$TECHNOLOGIES" 2>/dev/null || true

    local count
    count=$(wc -l < "$LIVE_HOSTS" | tr -d ' ')
    success "Found ${count} live hosts → ${LIVE_HOSTS}"
    success "Technologies fingerprinted → ${TECHNOLOGIES}"
}

# ── Stage 4: Nmap ─────────────────────────────────────────────────────────────
stage_nmap() {
    banner "Stage 4 — Port Scanning (Nmap)"
    if [[ "$SKIP_NMAP" == "true" ]]; then
        warn "Skipping: --skip-nmap flag set"
        return
    fi
    if ! command -v nmap &>/dev/null; then
        warn "Skipping: nmap not installed"
        return
    fi
    if [[ ! -s "$LIVE_HOSTS" ]]; then
        warn "Skipping: live_hosts.txt is empty"
        return
    fi

    # Extract base URLs → IPs/hostnames for nmap
    local targets_file="${OUTPUT_DIR}/nmap_targets.txt"
    awk '{print $1}' "$LIVE_HOSTS" | \
        sed 's|https\?://||' | \
        cut -d'/' -f1 | \
        sort -u > "$targets_file"

    local target_count
    target_count=$(wc -l < "$targets_file" | tr -d ' ')
    info "Scanning top ${NMAP_TOP_PORTS} ports on ${target_count} targets..."
    info "Mode: service version detection (--version-intensity 8) + default NSE scripts"

    nmap \
        -iL "$targets_file" \
        --top-ports "$NMAP_TOP_PORTS" \
        -sV \
        --version-intensity 8 \
        -sC \
        -T4 \
        --open \
        -oN "$PORTS" \
        -oX "${OUTPUT_DIR}/ports.xml" \
        -oG "${OUTPUT_DIR}/ports.gnmap"

    # ── Parse a clean service version table from grepable output ──────────────
    local svc_table="${OUTPUT_DIR}/service_versions.txt"
    {
        printf "%-45s %-7s %-12s %s\n" "HOST" "PORT" "PROTO" "SERVICE / VERSION"
        printf '%0.s─' {1..90}; echo
        grep "^Host:" "${OUTPUT_DIR}/ports.gnmap" 2>/dev/null | while IFS= read -r line; do
            local host
            host=$(echo "$line" | grep -oP 'Host: \K[^\s]+' || true)
            echo "$line" | grep -oP '\d+/open/[^/]*/[^/]*/[^\t/]*' 2>/dev/null | \
            while IFS='/' read -r port _ proto _ service_version; do
                printf "%-45s %-7s %-12s %s\n" \
                    "$host" "$port" "$proto" "$service_version"
            done
        done
    } > "$svc_table" || warn "service_versions.txt parsing failed — skipping"

    local open_count
    open_count=$(grep -c "^[0-9].*open" "$PORTS" 2>/dev/null || echo 0)
    success "${open_count} open ports found → ${PORTS}"
    success "Service version table → ${svc_table}"
    echo ""
    info "Service version summary:"
    if [[ -s "$svc_table" ]]; then
        if [[ $(wc -l < "$svc_table") -le 60 ]]; then
            cat "$svc_table"
        else
            head -n 30 "$svc_table"
            warn "... (truncated — see ${svc_table} for full output)"
        fi
    else
        warn "service_versions.txt is empty — check ports.gnmap manually"
    fi
}

# ── Stage 5: Katana ───────────────────────────────────────────────────────────
stage_katana() {
    banner "Stage 5 — Web Crawling (Katana)"
    if ! command -v katana &>/dev/null; then
        warn "Skipping: katana not installed"
        return
    fi
    if [[ ! -s "$LIVE_HOSTS" ]]; then
        warn "Skipping: live_hosts.txt is empty"
        return
    fi

    # Feed just the URLs (first column) to katana
    awk '{print $1}' "$LIVE_HOSTS" | \
    katana \
        -list /dev/stdin \
        -depth "$KATANA_DEPTH" \
        -silent \
        -concurrency "$THREADS" \
        -o "$CRAWL_URLS"

    local count
    count=$(wc -l < "$CRAWL_URLS" | tr -d ' ')
    success "Crawled ${count} URLs → ${CRAWL_URLS}"
}

# ── Stage 6: Nuclei ───────────────────────────────────────────────────────────
stage_nuclei() {
    banner "Stage 6 — Vulnerability Scanning (Nuclei)"
    if [[ "$SKIP_NUCLEI" == "true" ]]; then
        warn "Skipping: --skip-nuclei flag set"
        return
    fi
    if ! command -v nuclei &>/dev/null; then
        warn "Skipping: nuclei not installed"
        return
    fi
    if [[ ! -s "$LIVE_HOSTS" ]]; then
        warn "Skipping: live_hosts.txt is empty"
        return
    fi

    mkdir -p "$NUCLEI_DIR"

    local targets_file="${NUCLEI_DIR}/targets.txt"
    awk '{print $1}' "$LIVE_HOSTS" > "$targets_file"

    info "Severity filter: ${NUCLEI_SEVERITY}"
    info "Targets: $(wc -l < "$targets_file") hosts"
    info "Updating nuclei templates..."
    nuclei -update-templates -silent 2>/dev/null || true

    info "Running nuclei scan — this may take several minutes..."
    nuclei \
        -l "$targets_file" \
        -severity "$NUCLEI_SEVERITY" \
        -c "$THREADS" \
        -o "$NUCLEI_OUT" \
        -jsonl "$NUCLEI_JSON" \
        -silent \
        -no-color \
        -stats

    if [[ ! -s "$NUCLEI_OUT" ]]; then
        warn "No findings at severity: ${NUCLEI_SEVERITY}"
        return
    fi

    local n_critical n_high n_medium
    n_critical=$(grep -c "\[critical\]" "$NUCLEI_OUT" 2>/dev/null || echo 0)
    n_high=$(grep    -c "\[high\]"     "$NUCLEI_OUT" 2>/dev/null || echo 0)
    n_medium=$(grep  -c "\[medium\]"   "$NUCLEI_OUT" 2>/dev/null || echo 0)
    local total=$(( n_critical + n_high + n_medium ))

    grep "\[critical\]" "$NUCLEI_OUT" > "${NUCLEI_DIR}/critical.txt" 2>/dev/null || true
    grep "\[high\]"     "$NUCLEI_OUT" > "${NUCLEI_DIR}/high.txt"     2>/dev/null || true
    grep "\[medium\]"   "$NUCLEI_OUT" > "${NUCLEI_DIR}/medium.txt"   2>/dev/null || true

    success "Nuclei scan complete — ${total} findings"
    echo ""
    echo -e "  ${RED}[CRITICAL]${RESET} ${n_critical}"
    echo -e "  ${RED}[HIGH]    ${RESET} ${n_high}"
    echo -e "  ${YELLOW}[MEDIUM]  ${RESET} ${n_medium}"
    echo ""
    success "Full findings → ${NUCLEI_OUT}"
    success "JSONL output  → ${NUCLEI_JSON}"
    success "Bucketed      → ${NUCLEI_DIR}/critical.txt / high.txt / medium.txt"

    if [[ -s "${NUCLEI_DIR}/critical.txt" ]]; then
        echo ""
        echo -e "${RED}${BOLD}── Critical Findings ────────────────────────${RESET}"
        cat "${NUCLEI_DIR}/critical.txt"
    fi
    if [[ -s "${NUCLEI_DIR}/high.txt" ]]; then
        echo ""
        echo -e "${RED}── High Findings ────────────────────────────${RESET}"
        cat "${NUCLEI_DIR}/high.txt"
    fi
}

# ── Summary report ────────────────────────────────────────────────────────────
write_summary() {
    banner "Pipeline Complete — Summary"

    local n_critical n_high n_medium
    n_critical=$(grep -c "\[critical\]" "$NUCLEI_OUT" 2>/dev/null || echo 0)
    n_high=$(grep    -c "\[high\]"     "$NUCLEI_OUT" 2>/dev/null || echo 0)
    n_medium=$(grep  -c "\[medium\]"   "$NUCLEI_OUT" 2>/dev/null || echo 0)

    {
        echo "========================================"
        echo "  Recon Summary — ${DOMAIN}"
        echo "  Generated: $(date)"
        echo "========================================"
        echo ""
        echo "[Subdomains]        $(wc -l < "$SUBDOMAINS"   2>/dev/null || echo 0)"
        echo "[Resolved]          $(wc -l < "$RESOLVED"     2>/dev/null || echo 0)"
        echo "[Live Hosts]        $(wc -l < "$LIVE_HOSTS"   2>/dev/null || echo 0)"
        echo "[Technologies]      $(wc -l < "$TECHNOLOGIES" 2>/dev/null || echo 0) unique"
        echo "[Open Ports]        $(grep -c "^[0-9].*open" "$PORTS" 2>/dev/null || echo 0)"
        echo "[Crawled URLs]      $(wc -l < "$CRAWL_URLS"   2>/dev/null || echo 0)"
        echo ""
        echo "[Nuclei Critical]   ${n_critical}"
        echo "[Nuclei High]       ${n_high}"
        echo "[Nuclei Medium]     ${n_medium}"
        echo ""
        echo "[Output Dir]        $OUTPUT_DIR"
        echo "[Log]               $LOG_FILE"
        echo ""
        echo "--- Files ---"
        ls -lh "$OUTPUT_DIR"
    } | tee "$SUMMARY"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    clear
    echo -e "${BOLD}${GREEN}"
    cat <<'BANNER'
  ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗
  ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║
  ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║
  ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║
  ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║
  ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝
BANNER
    echo -e "  Automated Recon Pipeline v1.1${RESET}"
    echo -e "  Target:   ${CYAN}${DOMAIN}${RESET}"
    echo -e "  Output:   ${CYAN}${OUTPUT_DIR}${RESET}"
    echo -e "  Severity: ${CYAN}${NUCLEI_SEVERITY}${RESET}"
    echo ""

    check_deps
    stage_subfinder
    stage_dnsx
    stage_httpx
    stage_nmap
    stage_katana
    stage_nuclei
    write_summary

    echo -e "\n${GREEN}${BOLD}[✓] Recon complete. Results in: ${OUTPUT_DIR}${RESET}\n"
}

main
