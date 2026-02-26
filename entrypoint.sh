#!/bin/bash
set -eo pipefail

FNAME=$(basename "$INPUT_FILE")
BASE="${FNAME%.xlsx}"
LOG_FILE="/app/logs/${BASE}.log"
OUTPUT_FILE="${OUTPUT_DIR}/${BASE}_output.xlsx"

mkdir -p "$OUTPUT_DIR" /app/logs

echo "======================================" | tee "$LOG_FILE"
echo "Container: $FNAME (Server $SERVER_ID)" | tee -a "$LOG_FILE"
echo "Framework-agnostic runner" | tee -a "$LOG_FILE"
echo "======================================" | tee -a "$LOG_FILE"

# ---- universal runner ----
RUN_CMD="python3 /app/scraper.py --input \"$INPUT_FILE\" --output \"$OUTPUT_FILE\""

# If xvfb exists → use it
if command -v xvfb-run >/dev/null 2>&1; then
    RUN_CMD="xvfb-run -a $RUN_CMD"
fi

echo "Running: $RUN_CMD" | tee -a "$LOG_FILE"

if eval $RUN_CMD 2>&1 | tee -a "$LOG_FILE"; then
    echo "SUCCESS: $FNAME" | tee -a "$LOG_FILE"
    EXIT_CODE=0
else
    echo "FAILED: $FNAME" | tee -a "$LOG_FILE"
    EXIT_CODE=1
fi

# ---- Upload outputs ----
if [ -f "$OUTPUT_FILE" ]; then
    aws s3 cp "$OUTPUT_FILE" \
        "s3://${S3_BUCKET}/${S3_OUTPUT_PREFIX}${BASE}_output.xlsx" \
        --region "$AWS_REGION" 2>&1 | tee -a "$LOG_FILE"
else
    echo "Output not found → skipping S3 upload" | tee -a "$LOG_FILE"
fi

aws s3 cp "$LOG_FILE" \
    "s3://${S3_BUCKET}/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/${BASE}.log" \
    --region "$AWS_REGION" || true

exit $EXIT_CODE