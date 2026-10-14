#!/bin/bash
# Usage:
# bash ScarHRD_Pipeline.sh <batch_ID> [-s|--stop-docker]
#
#   -s, --stop-docker   After a successful run, stop Docker again - but ONLY if this
#                        script was the one that started it. If Docker was already
#                        running before this script ran, it's left running either way
#                        (this script isn't the one that brought it up, so it's not
#                        this script's place to take it down - something else on this
#                        shared machine may depend on it staying up).

set -o pipefail   # so a failure inside a `... | tee ...` pipeline is still detected

START_TIME="$(date +%s)"

# Formats a duration in whole seconds as "Hh Mm Ss" (hours omitted if zero)
format_duration() {
    local total=$1 h m s
    h=$((total / 3600)); m=$(((total % 3600) / 60)); s=$((total % 60))
    if [ "$h" -gt 0 ]; then
        printf '%dh %dm %ds' "$h" "$m" "$s"
    else
        printf '%dm %ds' "$m" "$s"
    fi
}

# Runs on every exit path (success or any of the "exit 1" error points below), so total time
# is always reported - even if the script fails partway through.
trap 'echo "Total time: $(format_duration $(( $(date +%s) - START_TIME )))"' EXIT

# Attempts to start + confirm ONE Docker backend ("desktop" or "engine").
# On success: sets DOCKER_BACKEND to that name and returns 0.
# On failure (service not registered, start command failed, or daemon never became
# reachable within 2 minutes): returns 1 and leaves DOCKER_BACKEND untouched, so the
# caller can try a different backend next.
try_start_docker_backend() {
    local backend=$1
    case "${backend}" in
        desktop)
            systemctl --user list-unit-files docker-desktop.service >/dev/null 2>&1 || return 1
            echo "Docker Desktop found - starting it (systemctl --user start docker-desktop)..."
            docker context use desktop-linux >/dev/null 2>&1 || true
            systemctl --user start docker-desktop
            if [ $? -ne 0 ]; then
                echo "Failed to start docker-desktop.service."
                return 1
            fi
            ;;
        engine)
            systemctl list-unit-files docker.service >/dev/null 2>&1 || return 1
            echo "Docker Engine found - starting it (sudo systemctl start docker)..."
            docker context use default >/dev/null 2>&1 || true
            sudo systemctl start docker
            if [ $? -ne 0 ]; then
                echo "Failed to start docker.service."
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    echo "Waiting for Docker (${backend}) to become ready..."
    for i in $(seq 1 60); do
        if docker info > /dev/null 2>&1; then
            echo "Docker (${backend}) is ready."
            DOCKER_BACKEND="${backend}"
            return 0
        fi
        echo "Docker not ready yet... ($i/60)"
        sleep 2
    done
    echo "Docker (${backend}) did not become ready within 2 minutes."
    return 1
}

# -----------------------------
# 0. Arg parsing (BATCH_ID stays positional for backwards compatibility; -s/--stop-docker
#    can appear anywhere on the command line)
# -----------------------------
STOP_DOCKER=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        -s|--stop-docker) STOP_DOCKER=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
BATCH_ID="${POSITIONAL[0]:-}"

if [ -z "$BATCH_ID" ]; then
    echo "Usage: bash ScarHRD_Pipeline.sh <batch_ID> [-s|--stop-docker]"
    exit 1
fi
echo "Starting HRD analysis for batch: $BATCH_ID"

# -----------------------------
# 1. Activate conda environment
# -----------------------------
source ~/miniconda3/etc/profile.d/conda.sh
conda activate hrd_env
if [ $? -ne 0 ]; then
    echo "ERROR: Could not activate hrd_env"
    exit 1
fi
echo "Conda environment activated: hrd_env"

# -----------------------------
# 2. Start Docker - only if it isn't already running. Preference order: Desktop first,
#    Engine as a real fallback if Desktop isn't installed/available or fails to come up.
#    Remembers whether WE started it (for the optional stop step later) and which backend
#    actually ended up working (DOCKER_BACKEND, used by both the wait logic and the stop step).
# -----------------------------
WE_STARTED_DOCKER=false
DOCKER_BACKEND=""

if docker info > /dev/null 2>&1; then
    echo "Docker is already running - skipping start."
else
    echo "Docker not running. Trying to start it automatically (Desktop first, then Engine)..."
    if try_start_docker_backend "desktop" || try_start_docker_backend "engine"; then
        WE_STARTED_DOCKER=true
    else
        echo "ERROR: Could not bring up a working Docker daemon via Desktop or Engine."
        echo "Install Docker Engine (https://docs.docker.com/engine/install/) or Docker Desktop for Linux,"
        echo "or check: systemctl --user status docker-desktop / systemctl status docker"
        exit 1
    fi
fi

# -----------------------------
# 3. Set up output + log folders
# -----------------------------
SEQZ_OUTPUT="./Seqz_${BATCH_ID}_Output"
SCARHRD_OUTPUT="./scarHRD_${BATCH_ID}_Output"
LOG_DIR="./logs_${BATCH_ID}"
mkdir -p "$SEQZ_OUTPUT" "$LOG_DIR"
echo "Created/verified: $SEQZ_OUTPUT"
echo "Logs will be written to: $LOG_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SEQZ_LOG="${LOG_DIR}/sequenza_${TIMESTAMP}.log"
SCARHRD_LOG="${LOG_DIR}/scarhrd_${TIMESTAMP}.log"

# -----------------------------
# 4. Run Sequenza
# -----------------------------
echo "Running Sequenza... (live output below, also logged to $SEQZ_LOG)"
./seqz_pipeline.sh \
    seqza_config.sh \
    samples.tsv \
    "$SEQZ_OUTPUT/" 2>&1 | tee "$SEQZ_LOG"

if [ $? -ne 0 ]; then
    echo "ERROR: Sequenza pipeline failed. See $SEQZ_LOG for details."
    exit 1
fi
echo "Sequenza completed successfully."

# -----------------------------
# 5. Run scarHRD
# -----------------------------
echo "Running scarHRD... (live output below, also logged to $SCARHRD_LOG)"
./run_scarhrd.sh \
    -i "$SEQZ_OUTPUT/" \
    -o "$SCARHRD_OUTPUT/" \
    -r grch37 2>&1 | tee "$SCARHRD_LOG"

if [ $? -ne 0 ]; then
    echo "ERROR: scarHRD pipeline failed. See $SCARHRD_LOG for details."
    exit 1
fi

echo "======================================"
echo "HRD analysis completed successfully."
echo "Batch: $BATCH_ID"
echo "Sequenza output: $SEQZ_OUTPUT (log: $SEQZ_LOG)"
echo "scarHRD output: $SCARHRD_OUTPUT (log: $SCARHRD_LOG)"
echo "======================================"

# -----------------------------
# 6. Optionally stop Docker again - ONLY if this script was the one that started it
# -----------------------------
if [ "$STOP_DOCKER" = true ]; then
    if [ "$WE_STARTED_DOCKER" = true ]; then
        case "$DOCKER_BACKEND" in
            engine)
                echo "Stopping Docker Engine (this script started it)..."
                sudo systemctl stop docker
                ;;
            desktop)
                echo "Stopping Docker Desktop (this script started it)..."
                systemctl --user stop docker-desktop
                ;;
        esac
    else
        echo "Docker was already running before this script started - leaving it running."
    fi
fi
