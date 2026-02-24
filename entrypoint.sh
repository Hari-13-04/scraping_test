#!/bin/bash
set -eo pipefail

FNAME=$(basename "$INPUT_FILE")
BASE="${FNAME%.xlsx}"
LOG_FILE="/app/logs/${BASE}.log"
OUTPUT_FILE="${OUTPUT_DIR}/${BASE}_output.xlsx"

mkdir -p "$OUTPUT_DIR" /app/logs

echo "======================================" | tee "$LOG_FILE"
echo "Container: $FNAME (Server $SERVER_ID)" | tee -a "$LOG_FILE"
echo "======================================" | tee -a "$LOG_FILE"

if python /app/scraper.py --input "$INPUT_FILE" --output "$OUTPUT_FILE" 2>&1 | tee -a "$LOG_FILE"; then
    echo "SUCCESS: $FNAME" | tee -a "$LOG_FILE"
    EXIT_CODE=0
else
    echo "FAILED: $FNAME" | tee -a "$LOG_FILE"
    EXIT_CODE=1
fi

if [ $EXIT_CODE -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
    echo "Uploading output to S3..." | tee -a "$LOG_FILE"
    aws s3 cp "$OUTPUT_FILE" \
        "s3://${S3_BUCKET}/${S3_OUTPUT_PREFIX}${BASE}_output.xlsx" \
        --region "$AWS_REGION" 2>&1 | tee -a "$LOG_FILE"
    echo "Upload complete." | tee -a "$LOG_FILE"
else
    echo "Skipping S3 upload (exit=$EXIT_CODE, file_exists=$(test -f "$OUTPUT_FILE" && echo yes || echo no))" | tee -a "$LOG_FILE"
fi

# Always upload log
aws s3 cp "$LOG_FILE" \
    "s3://${S3_BUCKET}/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/${BASE}.log" \
    --region "$AWS_REGION" || true

exit $EXIT_CODE
