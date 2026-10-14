#!/usr/bin/env bash
#
# Usage:
#   ./install_hrd_pipeline_engine.sh [-f <fasta_path>] [-l <lock_file>] [-y] [-h]
#   ./install_hrd_pipeline_engine.sh -f path/to/fasta/file
#
#   -f <fasta_path>  Path to the reference FASTA. If omitted, you'll be prompted.
#   -l <lock_file>   Conda-lock file name to use. Default: seqza_py310-linux-64.lock.yml
#   -y               Non-interactive: fail instead of prompting for missing input.
#   -h               Show this help.
set -uo pipefail
# -u: reference to an unset variable is an error (catches typos in var names)
# -o pipefail: a pipeline's exit status is its last non-zero component, not just the final command
# (no -e: many steps here check a command's exit code themselves and decide whether to warn or die,
#  so we don't want the shell auto-exiting on the first failure)

# Detects whether Docker Engine or Docker Desktop is present, prints install commands for whichever is missing,
# and - if Docker IS installed but its daemon is inactive - AUTOMATICALLY starts
# it (sudo systemctl start docker for Engine, or systemctl --user start
# docker-desktop for Desktop) instead of just telling you to do it yourself.
#
# NOTE: auto-starting via 'sudo systemctl start docker' will prompt for a sudo
# password if this shell doesn't already have passwordless sudo cached/configured
# for that command - it is not truly unattended unless you've set that up.
#
# Installer/verifier for the ScarHRD/Sequenza HRD pipeline on a new
# Linux system. Run this from the directory you transferred, which must
# contain (alongside this script):
#   - a GC50 wig file            (e.g. hg19.gc50Base.wig.gz)
#   - the conda-lock file        (default: seqza_py310-linux-64.lock.yml)
#   - seqz_pipeline.sh and run_scarhrd.sh
#   - BAM and index (.bai) files both should be present
#
# Prompt for fasta file

############################################
# Config / defaults
############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
START_TIME="$(date +%s)"   # epoch seconds at script start, used to log total elapsed time at the end
LOG_FILE="${SCRIPT_DIR}/install_hrd_pipeline_engine_${TIMESTAMP}.log"

ENV_NAME="hrd_env"                              # conda env name to create/verify (fixed, not a flag)
LOCK_FILE_NAME="seqza_py310-linux-64.lock.yml"  # conda-lock file name to look for (overridable with -l)
DOCKER_IMAGE="hydragenetics/scarhrd:20200825"   # frozen scarHRD image (pinned tag, not "latest")
CONFIG_OUT="${SCRIPT_DIR}/seqza_config.sh"      # generated config consumed by seqz_pipeline.sh
FASTA_PATH=""                                   # filled in via -f or the interactive prompt below
NON_INTERACTIVE=false                           # set by -y; turns missing-input prompts into hard failures

declare -A STATUS   # step -> OK | SKIPPED | FAILED, collected as we go and printed in print_summary

############################################
# Logging helpers
############################################

log()  { local msg="[$(date '+%F %T')] [INFO]  $*";  echo "${msg}"; echo "${msg}" >> "${LOG_FILE}"; }
warn() { local msg="[$(date '+%F %T')] [WARN]  $*";  echo "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
err()  { local msg="[$(date '+%F %T')] [ERROR] $*";  echo "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
die()  { err "$*"; err "Aborting installation."; print_summary; exit 1; }

set_status() { STATUS["$1"]="$2"; }

# Formats a duration in whole seconds as "Hh Mm Ss" (hours omitted if zero)
format_duration() {
    local total=$1 h m s
    h=$((total / 3600)); m=$(((total % 3600) / 60)); s=$((total % 60))
    if [[ ${h} -gt 0 ]]; then
        printf '%dh %dm %ds' "${h}" "${m}" "${s}"
    else
        printf '%dm %ds' "${m}" "${s}"
    fi
}

# Attempts to start + confirm ONE Docker backend ("engine" or "desktop").
# On success: sets DOCKER_BACKEND to that name and returns 0.
# On failure (service not registered, start command failed, or daemon never became
# reachable within 30s): returns 1 and leaves DOCKER_BACKEND untouched, so the caller
# can try a different backend next - this is what makes real fallback possible.
try_start_docker_backend() {
    local backend=$1
    case "${backend}" in
        engine)
            systemctl list-unit-files docker.service >/dev/null 2>&1 || return 1
            log "  Trying Docker Engine (docker.service)..."
            warn "  (starting it may prompt for a sudo password unless already cached/passwordless)"
            # Point the CLI at Engine's own context (unix:///var/run/docker.sock) explicitly -
            # otherwise 'docker info' checks whatever context was last selected (e.g.
            # 'desktop-linux' from prior manual use), which would report the daemon as
            # unreachable even if Engine started successfully.
            docker context use default >/dev/null 2>&1 || true
            if ! sudo systemctl start docker; then
                warn "  Failed to start docker.service. Check: systemctl status docker / journalctl -u docker"
                return 1
            fi
            ;;
        desktop)
            systemctl --user list-unit-files docker-desktop.service >/dev/null 2>&1 || return 1
            log "  Trying Docker Desktop (docker-desktop.service)..."
            docker context use desktop-linux >/dev/null 2>&1 || true
            if ! systemctl --user start docker-desktop; then
                warn "  Failed to start docker-desktop.service."
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    # Poll rather than a single fixed wait: Docker Desktop's backend (a VM) can take well
    # over a few seconds to actually create its socket after the service reports "started".
    log "  Waiting for the ${backend} daemon to become reachable (up to 30s)..."
    for _ in $(seq 1 10); do
        if docker info >/dev/null 2>&1; then
            DOCKER_BACKEND="${backend}"
            return 0
        fi
        sleep 3
    done
    warn "  ${backend} daemon did not become reachable within 30s."
    return 1
}

usage() {
    # Only the CONTIGUOUS block of '#' lines starting at the very top of the file (stops at
    # the first non-'#' line, i.e. 'set -uo pipefail') - not grep '^#', which would match
    # every top-level '#' comment in the whole script, not just the header.
    awk '/^#/{print; next} {exit}' "${BASH_SOURCE[0]}" | sed -e '1d' -e 's/^#//' -e 's/^ //'
    exit 1
}

############################################
# Arg parsing
# - f) FASTA_PATH=${OPTARG} ;; - if the flag was -f, take the value that came after it ($OPTARG, e.g. /path/to/hg19.fasta) and store it in FASTA_PATH.
# - l) LOCK_FILE_NAME=${OPTARG} ;; - same idea for -l.
# - y) NON_INTERACTIVE=true ;; - -y has no value, it just flips a yes/no switch to true.
# - h) usage ;; - -h calls the usage function (prints help and exits).
# - *) usage ;; - catch-all: if someone types a flag that isn't in the rulebook (like -x), also show usage and exit, instead of silently ignoring it.
############################################

# getopts flag string: f/l take a value (colon), y and h are plain switches
# (no 'e' here - the conda env name is fixed at "hrd_env", see ENV_NAME above)
while getopts "f:l:yh" opt; do
    case ${opt} in
        f) FASTA_PATH=${OPTARG} ;;
        l) LOCK_FILE_NAME=${OPTARG} ;;
        y) NON_INTERACTIVE=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

: > "${LOG_FILE}"
log "HRD pipeline installer starting (Docker Engine auto-start variant)"
log "Working directory: ${SCRIPT_DIR}"
log "Log file:          ${LOG_FILE}"

log "----------------------------------------"
log "Before running, this folder should contain:"
log "  - seqz_pipeline.sh"
log "  - run_scarhrd.sh"
log "  - a GC50 wig file (e.g. hg19.gc50Base.wig.gz)"
log "  - the conda-lock file (default: seqza_py310-linux-64.lock.yml)"
log "    -> only required if the '${ENV_NAME}' conda env doesn't already exist on this machine"
log "(the reference FASTA is NOT required here - you'll be prompted for its path in Step 7)"
log "----------------------------------------"

############################################
# Summary printer
############################################

print_summary() {
    log "----------------------------------------"
    log "Installation summary"
    log "----------------------------------------"
    for step in \
        "pipeline_scripts" "gc50_file" "lock_file" \
        "docker_installed" "docker_daemon" "docker_image" "scarhrd_r_loaded" \
        "conda_installed" "conda_lock_installed" "conda_env" "sequenza_utils" \
        "fasta_reference" "config_written"; do
        if [[ -n "${STATUS[$step]:-}" ]]; then
            log "$(printf '%-22s : %s' "${step}" "${STATUS[$step]}")"
        fi
    done
    log "----------------------------------------"
    log "Total time: $(format_duration $(( $(date +%s) - START_TIME )))"
    log "Full log: ${LOG_FILE}"
}

############################################
# Modified: Early Dependency Check: pipx
############################################
if ! command -v pipx >/dev/null 2>&1; then
    echo ""
    echo "============================================================"
    echo "[ERROR] 'pipx' is required but not installed on this system."
    echo "Please run the following commands manually to set it up:"
    echo ""
    echo "  sudo apt install pipx"
    echo "  pipx ensurepath"
    echo ""
    echo "After running those commands, RESTART your terminal"
    echo "and then run this installation script again."
    echo "============================================================"
    echo ""
    die "Missing pipx dependency. See instructions above."
fi


############################################
# 1) Required pipeline scripts present
############################################

log "Step 1/8: Checking pipeline scripts are present"

MISSING_SCRIPTS=()
for f in seqz_pipeline.sh run_scarhrd.sh ScarHRD_Pipeline.sh; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then # — does that file actually exist in the script's directory? (-f = "is a regular file".)
        chmod +x "${SCRIPT_DIR}/${f}"
        log "  Found and made executable: ${f}"
    else
        MISSING_SCRIPTS+=("${f}")
    fi
done

if [[ ${#MISSING_SCRIPTS[@]} -gt 0 ]]; then
    set_status "pipeline_scripts" "FAILED"
    die "Missing required script(s): ${MISSING_SCRIPTS[*]}. Transfer them into ${SCRIPT_DIR} and re-run."
fi
set_status "pipeline_scripts" "OK"

############################################
# 2) GC50 wig file present
#find "${SCRIPT_DIR}" -maxdepth 1 -iname "*gc50Base*.wig.gz": Search only directly inside SCRIPT_DIR (-maxdepth 1 = don't go into subfolders) for anything whose name contains gc50Base and ends in .wig.gz, case-insensitively (-iname). This matches things like hg19.gc50Base.wig.gz or HG19.GC50BASE.WIG.GZ.
#2>/dev/null — silently throw away any error messages find might print (e.g. permission errors), so they don't clutter the output.
#Normally IFS (default: space/tab/newline) tells bash where to split words and also makes read strip leading/trailing whitespace off what it reads. Setting it to empty means: "don't strip anything" — so a filename like "  my file.txt" or one with trailing spaces comes through exactly as-is, untouched.
#read -r — reads one chunk of input into a variable. The -r flag means "raw" — don't treat backslashes (\) as escape characters. Without -r, a filename containing a backslash could get mangled.
#-d '' — tells read to use an empty delimiter, which bash interprets as a null byte (\0) instead of the default newline. This matters because the file list is coming from find ... -print0 (seen in the line below this one), which separates filenames with null bytes specifically because filenames can legally contain newlines or spaces — but never a null byte. So this is the reading half of a matched pair: find -print0 writes null-separated, read -d '' reads null-separated.
#f — the variable name that each chunk gets stored into. So each time through the loop, f holds exactly one full filename.
#look for any file that looks like a GC50 wig file next to the script; stop with an error if none exist; warn (but continue) if more than one exists; otherwise just use whichever one was found.
############################################

log "Step 2/8: Checking GC50 reference wig file is present"

GC50_MATCHES=() #start an empty array to collect whatever matching files are found
# find ... -print0 / read -d '' : null-delimited so filenames with spaces don't break the loop
while IFS= read -r -d '' f; do
    GC50_MATCHES+=("${f}")
done < <(find "${SCRIPT_DIR}" -maxdepth 1 -iname "*gc50Base*.wig.gz" -print0 2>/dev/null)

if [[ ${#GC50_MATCHES[@]} -eq 0 ]]; then
    set_status "gc50_file" "FAILED"
    die "No GC50 wig file (*gc50Base*.wig.gz) found in ${SCRIPT_DIR}. Transfer it and re-run."
elif [[ ${#GC50_MATCHES[@]} -gt 1 ]]; then
    warn "  Multiple GC50 candidates found, using the first: ${GC50_MATCHES[0]}"
    for m in "${GC50_MATCHES[@]}"; do warn "    - ${m}"; done
fi
GC50_PATH="${GC50_MATCHES[0]}"
log "  Using GC50 file: ${GC50_PATH}"
set_status "gc50_file" "OK"

############################################
# 3) Conda-lock file present
############################################

log "Step 3/8: Checking conda-lock file is present"

LOCK_PATH="${SCRIPT_DIR}/${LOCK_FILE_NAME}"
if [[ -f "${LOCK_PATH}" ]]; then
    log "  Found lock file: ${LOCK_PATH}"
    set_status "lock_file" "OK"
else
    warn "  Conda-lock file not found: ${LOCK_PATH}"
    warn "  This is only a problem if the '${ENV_NAME}' conda env doesn't already exist (checked in Step 6)."
    set_status "lock_file" "MISSING (only needed if ${ENV_NAME} doesn't already exist)"
fi

############################################
# 4) Docker: Engine vs Desktop detection, install commands, AUTO-START if inactive
############################################

log "Step 4/8: Checking Docker (Engine/Desktop auto-detect, auto-start if inactive)"

DOCKER_OK=true   # tracks whether it's safe to attempt the image pull / R load check below
WE_STARTED_DOCKER=false   # true only if THIS run started Docker - used to stop it again at
                           # the very end, since this installer is a one-time setup script and
                           # has no ongoing reason to leave Docker running afterward (unlike
                           # ScarHRD_Pipeline.sh, which is run repeatedly and leaves it up by default)
DOCKER_BACKEND=""          # "engine" or "desktop" - whichever one ends up actually working

# 4a) Package configuration sanity check (Debian/Ubuntu only) - catches a real failure mode
# seen before: docker-ce "unpacked but not configured" (dpkg status 'iU') after an interrupted
# install, which looks present but isn't actually functional yet.
if command -v dpkg >/dev/null 2>&1; then
    PKG_LINE="$(dpkg -l docker-ce 2>/dev/null | tail -1)"
    if [[ "${PKG_LINE}" == iU* ]]; then
        warn "  docker-ce package is unpacked but NOT configured (broken/incomplete install)."
        warn "  Fix with: sudo apt --fix-broken install && sudo dpkg --configure -a"
    fi
fi

# 4b) docker CLI on PATH, with fallback to common install locations (same as base script)
DOCKER_BIN=""
if command -v docker >/dev/null 2>&1; then
    DOCKER_BIN="$(command -v docker)"
else
    for candidate in /usr/bin/docker /usr/local/bin/docker /snap/bin/docker /opt/docker/bin/docker; do
        if [[ -x "${candidate}" ]]; then
            DOCKER_BIN="${candidate}"
            CANDIDATE_DIR="$(dirname "${candidate}")"
            warn "  docker found at ${DOCKER_BIN}, but it is not on \$PATH for this shell."
            warn "  Make sure docker is added to PATH permanently, e.g.:"
            warn "    echo 'export PATH=\"${CANDIDATE_DIR}:\$PATH\"' >> ~/.bashrc"
            export PATH="${CANDIDATE_DIR}:${PATH}"
            break
        fi
    done
fi

if [[ -z "${DOCKER_BIN}" ]]; then
    warn "  Docker is not installed (checked \$PATH and common install locations). Choose one:"
    # Links only, not reproduced commands - Docker's own docs are the single source of truth
    # and can change format over time (already happened once - see git history/prior version
    # of this block), so point at them rather than duplicating install steps here.
    warn "    Docker Engine (no GUI, headless-friendly): https://docs.docker.com/engine/install/ubuntu/"
    warn "    Docker Desktop for Linux (GUI, own bundled engine, needs a desktop environment): https://docs.docker.com/desktop/setup/install/linux/"
    warn "  then re-run."
    warn "  Skipping Docker image pull and scarHRD load check."
    set_status "docker_installed" "FAILED"
    set_status "docker_daemon" "SKIPPED"
    set_status "docker_image" "SKIPPED"
    set_status "scarhrd_r_loaded" "SKIPPED"
    DOCKER_OK=false
    # Deliberately not a die(): Docker is only needed for stage 3 (scoring), so seqz generation
    # (stage 2) can still be verified/run without it.
else
    log "  docker binary found: ${DOCKER_BIN}"
    set_status "docker_installed" "OK"

    if docker info >/dev/null 2>&1; then
        log "  Docker daemon is reachable."
        set_status "docker_daemon" "OK"
    else
        warn "  Docker daemon not reachable. Trying to bring one up automatically..."
        warn "  (preference order: Desktop first, then Engine as a fallback)"

        # Real fallback: if Desktop doesn't pan out (not installed, fails to start, or never
        # becomes reachable within 30s), genuinely try Engine next - not just detect-and-quit.
        if try_start_docker_backend "desktop" || try_start_docker_backend "engine"; then
            log "  Docker daemon is now reachable via ${DOCKER_BACKEND}."
            set_status "docker_daemon" "OK (auto-started via ${DOCKER_BACKEND})"
            WE_STARTED_DOCKER=true
        else
            warn "  Could not bring up a working Docker daemon via Desktop or Engine."
            warn "  Check: systemctl status docker --no-pager / journalctl -u docker -n 50 --no-pager"
            warn "         systemctl --user status docker-desktop --no-pager / journalctl --user -u docker-desktop -n 50 --no-pager"
            warn "  If permission denied: sudo usermod -aG docker \$USER && newgrp docker"
            #journalctl reads the systemd journal — the actual detailed log history for a service (way more than the few lines systemctl status shows inline).
            #-u docker / -u docker-desktop — filter to just that one service's log entries (-u = "unit"), instead of the entire system's journal.
            #--user — same reasoning as above: Desktop's logs live in the user-level journal, not the system one.
            #-n 50 — only show the last 50 lines, rather than the service's entire history since it was first installed (which could be huge and mostly irrelevant).
            #--no-pager — same as above, dump straight to terminal rather than opening a pager.
            set_status "docker_daemon" "FAILED"
            set_status "docker_image" "SKIPPED"
            set_status "scarhrd_r_loaded" "SKIPPED"
            DOCKER_OK=false
        fi
    fi

    if [[ "${DOCKER_OK}" == true ]]; then
        if [[ -n "$(docker images -q "${DOCKER_IMAGE}" 2>/dev/null)" ]]; then
            log "  Docker image already present: ${DOCKER_IMAGE}"
            set_status "docker_image" "OK"
        else
            log "  Pulling Docker image: ${DOCKER_IMAGE} (this may take a while)"
            if docker pull "${DOCKER_IMAGE}" >> "${LOG_FILE}" 2>&1; then
                log "  Docker image pulled successfully."
                set_status "docker_image" "OK"
            else
                err "  Failed to pull Docker image ${DOCKER_IMAGE}."
                set_status "docker_image" "FAILED"
                DOCKER_OK=false
            fi
        fi
    fi
fi

if [[ "${DOCKER_OK}" == true ]]; then
    log "  Verifying scarHRD R package loads inside the container..."
    R_CHECK_OUT=$(docker run --rm "${DOCKER_IMAGE}" R --vanilla --slave -e \
        'if (!requireNamespace("scarHRD", quietly=TRUE)) { cat("MISSING\n"); quit(status=1) } else { cat("scarHRD", as.character(packageVersion("scarHRD")), "\n"); quit(status=0) }' \
        2>&1)
    R_CHECK_RC=$?
    echo "${R_CHECK_OUT}" >> "${LOG_FILE}"
    if [[ ${R_CHECK_RC} -eq 0 ]]; then
        log "  scarHRD loaded OK inside container: $(echo "${R_CHECK_OUT}" | tail -1)"
        set_status "scarhrd_r_loaded" "OK"
    else
        err "  scarHRD failed to load inside the container. See ${LOG_FILE} for details."
        set_status "scarhrd_r_loaded" "FAILED"
    fi
fi

############################################
# 5) Conda / conda-lock / hrd_env
############################################

log "Step 5/8: Checking conda"

# conda itself is deliberately NOT auto-installed here. command -v looks up the path of conda in the path env variables e.g., /home/user/miniconda3/bin/conda
if ! command -v conda >/dev/null 2>&1; then
    set_status "conda_installed" "FAILED"
    die "conda is not installed. Install Miniconda/Anaconda first, then re-run this script."
fi
log "  conda found: $(command -v conda)"
set_status "conda_installed" "OK"

# Enable 'conda activate' / 'conda run' in this shell
# (a plain non-interactive script's shell doesn't have conda's activation hooks wired in by default, acts like conda init bash which writes in bashrc to accept & run conda activate commands)
eval "$(conda shell.bash hook)"

log "Step 6/8: Checking conda-lock"

# Unlike conda itself, conda-lock is a small, self-contained conda package - safe to auto-install
# into the base env without touching PATH/shell rc files, so we do it automatically here
# If conda lock not found in the Path then revert the results in output, instead of terminal (dev/null 2>&1)
# if ! command -v conda-lock >/dev/null 2>&1; then
#     log "  conda-lock not found. Installing via 'conda install -c conda-forge conda-lock'..."
#     if conda install -y -c conda-forge conda-lock >> "${LOG_FILE}" 2>&1; then
#         log "  conda-lock installed."
#         set_status "conda_lock_installed" "OK"
#     else
#         set_status "conda_lock_installed" "FAILED"
#         die "Failed to install conda-lock. See ${LOG_FILE}."
#     fi
# else
#     log "  conda-lock already installed: $(conda-lock --version 2>&1 | tr -d '\n')"
#     set_status "conda_lock_installed" "OK"
# fi

# Modified: Using pipx instead of conda. When we run this script, a non-interactive subshell opens which ignores ~/.bashrc. Because of this, the Conda 'base' environment is never loaded into the script's PATH. Conda successfully downloads conda-lock, but the script can't find it.
#command -v pipx: where the pipx command is and it prints path (usr/bin/pipx) -> hidden success status (0) & failure status (0)
if ! command -v conda-lock >/dev/null 2>&1; then
    log "conda-lock not found. Installing via 'pipx install conda-lock'"
    if pipx install conda-lock >> "${LOG_FILE}" 2>&1; then
        log "conda-lock installed via pipx"
        set_status "conda_lock_installed" "OK"
        export PATH="$HOME/.local/bin:$PATH"
    else
        set_status "conda_lock_installed" "FAILED"
        die "Failed to install conda-lock via pipx. See ${LOG_FILE}."
    fi
else
    log "conda-lock already installed: $(conda-lock --version 2>&1 | tr -d '\n')"
    set_status "conda_lock_installed" "OK"
    # Ensure conda-lock is available in PATH just in case it wasn't picked up automatically by the shell environment
    export PATH="$HOME/.local/bin:$PATH"
fi

log "  Checking whether conda env '${ENV_NAME}' already exists..."
# `conda env list` prints env paths with the env name as the first column ('*' marks the active one);
# awk: column processing, it will print only 1st column containing all the env names and grep will fetch exactly hrd_env using -x and -q will help in not printing anything
# grep -qx does an exact whole-line match so "hrd_env2" doesn't false-positive for "hrd_env"
if conda env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
    log "  Env '${ENV_NAME}' already exists. Skipping creation."
    set_status "conda_env" "OK (already existed)"
else
    if [[ ! -f "${LOCK_PATH}" ]]; then
        set_status "conda_env" "FAILED"
        die "Env '${ENV_NAME}' doesn't exist and no conda-lock file was found at ${LOCK_PATH} to create it from. Transfer it (or pass -l <name>) and re-run."
    fi

    log "  Creating env '${ENV_NAME}' from ${LOCK_PATH} (this may take a while)..."
    # cd into SCRIPT_DIR first: conda-lock install is run from the directory containing
    # the lock file (see Notes.txt), so we shell out to a subshell cd rather than changing $PWD globally
    if (cd "${SCRIPT_DIR}" && conda-lock install -n "${ENV_NAME}" "${LOCK_FILE_NAME}") >> "${LOG_FILE}" 2>&1; then
        log "  Env '${ENV_NAME}' created."
        set_status "conda_env" "OK (created)"
    else
        set_status "conda_env" "FAILED"
        die "Failed to create conda env from lock file. See ${LOG_FILE}."
    fi
fi

log "  Verifying sequenza-utils is available in '${ENV_NAME}'..."
# `conda run -n <env> command -v ...` checks for the binary inside that env without needing to `conda activate` it in this shell first
if conda run -n "${ENV_NAME}" command -v sequenza-utils >/dev/null 2>&1; then
    # sequenza-utils has no --version flag; its bare usage banner (first line) is enough to prove
    # it's runnable, so we just capture that instead of trying to parse a version number. Just checking if sequenza-utils runs its python interpreter
    # above will check if sequenza_utils present in hrd_env and below will run sequenza-utils to check if it is running
    SEQZ_VER=$(conda run -n "${ENV_NAME}" sequenza-utils 2>&1 | head -1)
    log "  sequenza-utils output: ${SEQZ_VER}"
    log "  sequenza-utils is installed and runnable."
    set_status "sequenza_utils" "OK"
else
    err "  sequenza-utils not found in env '${ENV_NAME}'."
    set_status "sequenza_utils" "FAILED"
fi

############################################
# 7) Reference FASTA path (interactive)
############################################

log "Step 7/8: Reference FASTA"

# The FASTA is the one asset too large to transfer with this script, so it's the only thing
# we ask for interactively rather than expecting it to already be sitting in SCRIPT_DIR
# while; do: (-z to check if empty = True and file path not found; keep looping while FASTA_PATH is empty OR the file it points to doesn't exist." So the loop only exits once we have a path that's both set and valid.
# Inner loop of if: if FASTA_PATH was set (non-empty, -n) but the file doesn't exist, warn about it — this only fires on a retry (a bad path was already typed), not on the very first pass when it's simply empty and nothing's been typed yet.
while [[ -z "${FASTA_PATH}" || ! -f "${FASTA_PATH}" ]]; do
    if [[ -n "${FASTA_PATH}" && ! -f "${FASTA_PATH}" ]]; then
        warn "  File not found: ${FASTA_PATH}"
    fi
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        set_status "fasta_reference" "FAILED"
        die "No valid FASTA path given (-f) and running in non-interactive mode (-y)."
    fi
    read -rp "Enter full path to the reference FASTA file (e.g. /path/to/hg19.fasta): " FASTA_PATH
done
# Normalise to an absolute path (mirrors run_scarhrd.sh's realpath usage) so the copy step
# below and seqza_config.sh don't end up with a path that's only valid relative to wherever
# this installer was launched from
FASTA_PATH="$(cd "$(dirname "${FASTA_PATH}")" && pwd)/$(basename "${FASTA_PATH}")"

# Copy the FASTA (and its .fai index, if present) into SCRIPT_DIR so the pipeline has its own
# self-contained local copy instead of REF_GENOME pointing at some other location on disk.
# NOTE: reference FASTAs are typically multi-GB, so this copy can take a while and roughly
# doubles disk usage (original + copy) unless you remove the original afterward.
FASTA_DEST="${SCRIPT_DIR}/$(basename "${FASTA_PATH}")"
if [[ "${FASTA_PATH}" == "${FASTA_DEST}" ]]; then
    log "  FASTA is already inside ${SCRIPT_DIR}; no copy needed."
elif [[ -f "${FASTA_DEST}" ]]; then
    log "  A copy already exists at ${FASTA_DEST}; skipping re-copy."
    FASTA_PATH="${FASTA_DEST}"
else
    log "  Copying FASTA into ${SCRIPT_DIR} (large file - this may take a while)..."
    # Check cp's exit code explicitly - a silent failure here (e.g. disk full, permission
    # denied) would otherwise leave FASTA_PATH pointing at a missing/truncated file while
    # the rest of the script keeps going and reports success.
    if ! cp "${FASTA_PATH}" "${FASTA_DEST}"; then
        set_status "fasta_reference" "FAILED"
        die "Failed to copy FASTA to ${FASTA_DEST} (check disk space and permissions on ${SCRIPT_DIR})."
    fi
    if [[ -f "${FASTA_PATH}.fai" ]]; then
        # .fai is just a rebuildable index (sequenza-utils can regenerate it), so a failed
        # copy here is worth a warning but shouldn't abort the whole install
        cp "${FASTA_PATH}.fai" "${FASTA_DEST}.fai" || warn "  Failed to copy .fai index (non-fatal, sequenza-utils can rebuild it)."
    fi
    FASTA_PATH="${FASTA_DEST}"
    log "  Copy complete: ${FASTA_PATH}"
fi

log "  Using reference FASTA: ${FASTA_PATH}"
if [[ ! -f "${FASTA_PATH}.fai" ]]; then
    # Not fatal - sequenza-utils can build the index itself - but worth flagging since it slows
    # the first pipeline run down
    warn "  No .fai index found next to the FASTA (${FASTA_PATH}.fai). sequenza-utils may need one."
fi
set_status "fasta_reference" "OK"

############################################
# 8) Write seqza_config.sh
############################################

log "Step 8/8: Writing seqza_config.sh"

if [[ -f "${CONFIG_OUT}" ]]; then
    # Never clobber a pre-existing config silently - back it up first in case it held
    # hand-tuned settings (e.g. a custom SEQZ_CHR_LIST) from a previous install.
    # If the backup itself fails, stop here rather than risk overwriting the only copy
    # of the existing config with nothing to fall back on.
    # Fixed name (not timestamped) - overwritten each run, so backups don't pile up over time.
    # Only the most recent previous config is ever kept.
    BACKUP="${CONFIG_OUT}.bak"
    if ! cp "${CONFIG_OUT}" "${BACKUP}"; then
        set_status "config_written" "FAILED"
        die "Failed to back up existing seqza_config.sh to ${BACKUP}; not overwriting it. Check permissions on ${SCRIPT_DIR}."
    fi
    log "  Existing seqza_config.sh backed up to $(basename "${BACKUP}")"
fi

# Heredoc writes the new config in the exact format seqz_pipeline.sh expects (source-able bash vars).
# Checked explicitly: a failed write here (e.g. disk full, permission denied) would otherwise
# be reported as "OK" even though seqza_config.sh was left missing or truncated.
if ! cat > "${CONFIG_OUT}" <<EOF
SEQZ_ENV="${ENV_NAME}"
REF_GENOME="${FASTA_PATH}"
GC50="${GC50_PATH}"

# Optional:
SEQZ_CHR_LIST="chr1 chr2 chr3 chr4 chr5 chr6 chr7 chr8 chr9 chr10 chr11 chr12 chr13 chr14 chr15 chr16 chr17 chr18 chr19 chr20 chr21 chr22 chrX chrY"
KEEP_CHR_SEQZ=true
EOF
then
    set_status "config_written" "FAILED"
    die "Failed to write ${CONFIG_OUT}. Check disk space and permissions on ${SCRIPT_DIR}."
fi

log "  Wrote ${CONFIG_OUT}"
set_status "config_written" "OK"

############################################
# Done
############################################

print_summary

# Best-effort disk usage breakdown across everything this install touched - each check is
# independent and skipped quietly (not fatal) if the thing it's measuring isn't available.
log "----------------------------------------"
log "Disk usage"
log "----------------------------------------"
log "  ${SCRIPT_DIR} (total): $(du -sh "${SCRIPT_DIR}" 2>/dev/null | cut -f1)"
if [[ -n "${FASTA_PATH:-}" && -f "${FASTA_PATH}" ]]; then
    log "  Reference FASTA: $(du -sh "${FASTA_PATH}" 2>/dev/null | cut -f1)"
fi
CONDA_ENV_PATH="$(conda env list 2>/dev/null | awk -v e="${ENV_NAME}" '$1==e {print $NF}')"
if [[ -n "${CONDA_ENV_PATH}" && -d "${CONDA_ENV_PATH}" ]]; then
    log "  Conda env '${ENV_NAME}': $(du -sh "${CONDA_ENV_PATH}" 2>/dev/null | cut -f1)"
fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_IMG_SIZE="$(docker images "${DOCKER_IMAGE}" --format '{{.Size}}' 2>/dev/null)"
    if [[ -n "${DOCKER_IMG_SIZE}" ]]; then
        log "  Docker image (${DOCKER_IMAGE}): ${DOCKER_IMG_SIZE}"
    fi
fi
log "----------------------------------------"

log "Installation complete."
log "Next steps:"
log "  1) Edit/create samples.tsv (Patient_ID<TAB>Normal_BAM<TAB>Tumor_BAM)"
log "  2) bash ScarHRD_Pipeline.sh <batch_ID>            # runs seqz_pipeline.sh + run_scarhrd.sh together"
log "     (add -s / --stop-docker to stop Docker afterward, but only if that run started it)"

# This installer only needs Docker briefly (to pull/verify the image) - since it's a one-time
# setup script, not something run repeatedly like ScarHRD_Pipeline.sh, clean up after itself:
# stop whichever backend it started, but ONLY if it was the one that started it (leave it
# alone if Docker was already running before this script ran).
if [[ "${WE_STARTED_DOCKER}" == true ]]; then
    log "Stopping Docker (${DOCKER_BACKEND}) since this installer started it..."
    case "${DOCKER_BACKEND}" in
        engine)  sudo systemctl stop docker ;;
        desktop) systemctl --user stop docker-desktop ;;
    esac
fi

exit 0
