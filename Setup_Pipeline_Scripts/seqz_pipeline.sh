#!/usr/bin/env bash
set -uo pipefail
shopt -s expand_aliases

############################################
# Usage
############################################

usage() {
    cat <<EOF
Usage: $(basename "$0") <CONFIG_FILE> <SAMPLE_SHEET> <OUT_DIR> [MAX_JOBS]

CONFIG_FILE  : Bash config defining SEQZ_ENV, REF_GENOME, GC50, etc.
SAMPLE_SHEET : TSV with header:
               Patient_ID<TAB>Tumor_BAM<TAB>Normal_BAM
OUT_DIR      : Root output directory for per-patient seqz folders
MAX_JOBS     : Max number of patients processed in parallel (default: 1)

Expected CONFIG_FILE variables:
  SEQZ_ENV        : conda env containing sequenza-utils
  REF_GENOME      : reference FASTA
  GC50            : GC wig file
  SEQZ_CHR_LIST   : (optional) space-separated chromosome list
                    default: chr1..chr22 chrX chrY
  KEEP_CHR_SEQZ   : (optional) 'true' or 'false'
                    - true  : keep per-chr seqz in tmp/chr (default)
                    - false : delete tmp/chr after final merge

Per-patient directory structure:
  <OUT_DIR>/<Patient_ID>/
      <Patient_ID>.seqz.gz
      <Patient_ID>.seqz.gz.tbi (if produced)
      tmp/
          chr/
              <Patient_ID>_chr1.seqz.gz
              <Patient_ID>_chr1.bam2seqz.log
              ...
          merge/
              <Patient_ID>.round1.0.seqz.gz
              ...

Note: This pipeline does NOT run seqz_binning (no small.seqz.gz).
EOF
    exit 1
}

############################################
# Arg parsing
############################################

if [[ $# -lt 3 ]]; then
    usage
fi

CONFIG_FILE=$1
SAMPLE_SHEET=$2
OUT_ROOT=$3
MAX_JOBS=${4:-1}

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
    exit 1
fi

if [[ ! -f "${SAMPLE_SHEET}" ]]; then
    echo "ERROR: Sample sheet not found: ${SAMPLE_SHEET}" >&2
    exit 1
fi

mkdir -p "${OUT_ROOT}"

############################################
# Load config & activate env
############################################

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Enable 'conda activate'
eval "$(conda shell.bash hook)"

# Activate the sequenza env globally
conda activate "${SEQZ_ENV}"

# Defaults
SEQZ_CHR_LIST_DEFAULT="chr1 chr2 chr3 chr4 chr5 chr6 chr7 chr8 chr9 chr10 chr11 chr12 chr13 chr14 chr15 chr16 chr17 chr18 chr19 chr20 chr21 chr22 chrX chrY"
SEQZ_CHR_LIST="${SEQZ_CHR_LIST:-$SEQZ_CHR_LIST_DEFAULT}"
KEEP_CHR_SEQZ="${KEEP_CHR_SEQZ:-true}"

############################################
# Dependency checks (after env activation)
############################################

check_cmd() {
    local cmd=$1
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: '${cmd}' not found in PATH." >&2
        exit 1
    fi
}

check_cmd "sequenza-utils"

############################################
# Core worker: per-patient seqz generation
############################################

bam2seqz_merge_patient() {
    local patient_id=$1
    local tumor_bam=$2
    local normal_bam=$3

    local out_dir="${OUT_ROOT}/${patient_id}"
    local tmp_chr_dir="${out_dir}/tmp/chr"
    local tmp_merge_dir="${out_dir}/tmp/merge"

    mkdir -p "${out_dir}" "${tmp_chr_dir}" "${tmp_merge_dir}"

    echo "[$(date '+%F %T')] [${patient_id}] START"
    echo "  Tumor BAM : ${tumor_bam}"
    echo "  Normal BAM: ${normal_bam}"
    echo "  Output dir: ${out_dir}"

    if [[ ! -f "${tumor_bam}" ]]; then
        echo "[$(date '+%F %T')] [${patient_id}] ERROR: Tumor BAM not found: ${tumor_bam}" >&2
        return 1
    fi
    if [[ ! -f "${normal_bam}" ]]; then
        echo "[$(date '+%F %T')] [${patient_id}] ERROR: Normal BAM not found: ${normal_bam}" >&2
        return 1
    fi

    ########################################
    # 1) Per-chromosome bam2seqz → tmp/chr
    ########################################

    for chr in ${SEQZ_CHR_LIST}; do
        local chr_out="${tmp_chr_dir}/${patient_id}_${chr}.seqz.gz"
        local chr_log="${tmp_chr_dir}/${patient_id}_${chr}.bam2seqz.log"

        echo "[$(date '+%F %T')] [${patient_id}] bam2seqz -> ${chr} (${chr_out})"

        # No --parallel here; we already parallelise over chromosomes.
        sequenza-utils bam2seqz \
            -t "${tumor_bam}" \
            -n "${normal_bam}" \
            --fasta "${REF_GENOME}" \
            -C "${chr}" \
            -gc "${GC50}" \
            -o "${chr_out}" \
            > "${chr_log}" 2>&1 &
    done

    wait
    echo "[$(date '+%F %T')] [${patient_id}] All per-chromosome bam2seqz jobs finished. Verifying outputs..."

    # Sanity check: all expected per-chr files must exist and be non-empty
    for chr in ${SEQZ_CHR_LIST}; do
        local chr_file="${tmp_chr_dir}/${patient_id}_${chr}.seqz.gz"
        if [[ ! -s "${chr_file}" ]]; then
            echo "[$(date '+%F %T')] [${patient_id}] ERROR: Missing or empty seqz for ${chr}: ${chr_file}" >&2
            echo "  Check log: ${tmp_chr_dir}/${patient_id}_${chr}.bam2seqz.log" >&2
            return 1
        fi
    done

    ########################################
    # 2) Hierarchical merge of seqz files
    #    tmp/chr → tmp/merge → final
    ########################################

    local files=()
    for chr in ${SEQZ_CHR_LIST}; do
        files+=("${tmp_chr_dir}/${patient_id}_${chr}.seqz.gz")
    done

    local round=1
    echo "[$(date '+%F %T')] [${patient_id}] Starting hierarchical merge (${#files[@]} files)..."

    while [[ ${#files[@]} -gt 1 ]]; do
        echo "[$(date '+%F %T')] [${patient_id}] Merge round ${round}: ${#files[@]} files"
        local new_files=()
        local temp_files=()

        for ((i=0; i<${#files[@]}; i+=2)); do
            if [[ $((i+1)) -lt ${#files[@]} ]]; then
                local outfile="${tmp_merge_dir}/${patient_id}.round${round}.$((i/2)).seqz.gz"
                echo "    Merging: ${files[i]} + ${files[i+1]} -> ${outfile}"

                sequenza-utils seqz_merge \
                    -o "${outfile}" \
                    -1 "${files[i]}" \
                    -2 "${files[i+1]}" &

                new_files+=("${outfile}")
                temp_files+=("${files[i]}" "${files[i+1]}")
            else
                # Odd file: carry forward
                new_files+=("${files[i]}")
            fi
        done

        wait
        echo "[$(date '+%F %T')] [${patient_id}] Cleaning inputs of round ${round} ..."
        for f in "${temp_files[@]}"; do
            rm -f "${f}" "${f}.tbi" || true
        done

        files=("${new_files[@]}")
        round=$((round + 1))
    done

    local final_file="${files[0]}"
    echo "[$(date '+%F %T')] [${patient_id}] Final merged seqz: ${final_file}"

    mv "${final_file}" "${out_dir}/${patient_id}.seqz.gz"
    if [[ -f "${final_file}.tbi" ]]; then
        mv "${final_file}.tbi" "${out_dir}/${patient_id}.seqz.gz.tbi"
    fi

    ########################################
    # 3) Cleanup temp dirs (according to KEEP_CHR_SEQZ)
    ########################################

    # Always remove merge intermediates
    rm -rf "${tmp_merge_dir}"

    # Normalise KEEP_CHR_SEQZ to lowercase for comparison
    local keep_chr="${KEEP_CHR_SEQZ,,}"

    if [[ "${keep_chr}" != "true" ]]; then
        echo "[$(date '+%F %T')] [${patient_id}] Removing per-chr seqz (KEEP_CHR_SEQZ=${KEEP_CHR_SEQZ})"
        rm -rf "${tmp_chr_dir}"
        # If tmp is now empty, remove it
        rmdir "${out_dir}/tmp" 2>/dev/null || true
    else
        echo "[$(date '+%F %T')] [${patient_id}] Keeping per-chr seqz in tmp/chr (KEEP_CHR_SEQZ=${KEEP_CHR_SEQZ})"
    fi

    # No seqz_binning here (explicitly skipped)
    echo "[$(date '+%F %T')] [${patient_id}] DONE (no binning)."
}

############################################
# Main loop over sample sheet
############################################

echo "Config file      : ${CONFIG_FILE}"
echo "Sample sheet     : ${SAMPLE_SHEET}"
echo "Output root      : ${OUT_ROOT}"
echo "Max parallel jobs: ${MAX_JOBS}"
echo "KEEP_CHR_SEQZ    : ${KEEP_CHR_SEQZ}"
echo ""

job_count=0

# Read TSV, skipping header
while IFS=$'\t' read -r patient_id normal_bam tumor_bam; do
    # Skip header or blank lines
    [[ "${patient_id}" == "Patient_ID" ]] && continue
    [[ -z "${patient_id}" ]] && continue

    echo "Scheduling patient: ${patient_id}"
    # NOTE: pass tumor_bam first, then normal_bam to the worker
    bam2seqz_merge_patient "${patient_id}" "${tumor_bam}" "${normal_bam}" &

    ((job_count++))
    if (( job_count >= MAX_JOBS )); then
        # Don't kill the whole script on one failed sample
        if ! wait; then
            echo "WARNING: One or more patient jobs in this batch failed." >&2
        fi
        job_count=0
    fi
done < "${SAMPLE_SHEET}"

# Final wait for any remaining jobs
if ! wait; then
    echo "WARNING: One or more patient jobs failed overall." >&2
fi

# Optional: drop back to base env
conda deactivate
