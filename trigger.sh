#!/bin/bash
set -e

# ── Redirect all output to a timestamped log file ────────────────────────────
# instance-agent.js tails the latest run_*.log for Live Log streaming
SCRAPER_DIR="/home/ubuntu/scraper"
mkdir -p "$SCRAPER_DIR/logs"
LOG_FILE="$SCRAPER_DIR/logs/run_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "TRIGGER.SH — $(date)"
echo "=========================================="

cd "$SCRAPER_DIR"

# ── Load config ───────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo "ERROR: .env not found at $SCRAPER_DIR/.env"
    echo "STATUS=error" > "$SCRAPER_DIR/status.txt"
    exit 1
fi
source .env

echo "Server ID : $SERVER_ID"
echo "Region    : $AWS_REGION"

# ── Write running status — instance-agent /status reads this ─────────────────
echo "STATUS=running" > "$SCRAPER_DIR/status.txt"

# ── Cleanup old containers ────────────────────────────────────────────────────
echo "[INFO] Cleaning up old containers..."
docker rm -f $(docker ps -aq --filter "name=scraper_")  2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=selenium_") 2>/dev/null || true
docker network rm scraper-net 2>/dev/null || true

rm -f output/*.xlsx logs/*.log 2>/dev/null || true

# ── Refresh IAM credentials ───────────────────────────────────────────────────
echo "[INFO] Refreshing IAM credentials..."
ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
CREDS=$(curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")

export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | python3 -c "import sys,json;print(json.load(sys.stdin)['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | python3 -c "import sys,json;print(json.load(sys.stdin)['Token'])")
echo "[INFO] IAM credentials refreshed"

# ── Pull latest code ──────────────────────────────────────────────────────────
echo "[INFO] Pulling latest code from $GITHUB_BRANCH..."
cd repo
git pull origin "$GITHUB_BRANCH" || echo "[WARN] git pull failed — continuing with existing code"
cd ..

# ── Build Docker image ────────────────────────────────────────────────────────
echo "[INFO] Building scraper Docker image..."
docker build -t scraper-image ./repo
echo "[INFO] Docker image built"

# ── Create network ────────────────────────────────────────────────────────────
docker network create scraper-net 2>/dev/null || true

# ── List input files ──────────────────────────────────────────────────────────
LOCAL_INPUT_DIR="$SCRAPER_DIR/input"
ls "$LOCAL_INPUT_DIR"/*.xlsx 2>/dev/null | xargs -n1 basename | sort > /tmp/my_files.txt || true
FILE_COUNT=$(grep -c . /tmp/my_files.txt 2>/dev/null || echo 0)

echo "[INFO] Input files found: $FILE_COUNT"
cat /tmp/my_files.txt

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "[WARN] No input files found in $LOCAL_INPUT_DIR — nothing to do"
    echo "STATUS=idle" > "$SCRAPER_DIR/status.txt"
    exit 0
fi

# ── Process files ─────────────────────────────────────────────────────────────
SUCCESS_COUNT=0
FAIL_COUNT=0
FILE_NUM=0

while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    FILE_NUM=$((FILE_NUM + 1))

    echo ""
    echo "--- File $FILE_NUM / $FILE_COUNT : $fname ---"

    SAFE=$(echo "$fname" | tr '. -' '_' | tr '[:upper:]' '[:lower:]')

    # Start Selenium with noVNC on port 7900
    docker run -d \
        --name "selenium_${SAFE}" \
        --network scraper-net \
        --shm-size="2g" \
        -p 4444:4444 \
        -p 7900:7900 \
        -e SE_NODE_MAX_SESSIONS=1 \
        -e SE_SESSION_REQUEST_TIMEOUT=300 \
        -e SE_VNC_NO_PASSWORD=1 \
        selenium/standalone-chrome:latest

    echo "[INFO] Waiting for Selenium..."
    for i in $(seq 1 30); do
        docker exec "selenium_${SAFE}" curl -sf http://localhost:4444/wd/hub/status \
            >/dev/null 2>&1 && echo "[INFO] Selenium ready (attempt $i)" && break
        sleep 2
    done

    docker run --name "scraper_${SAFE}" \
        --network scraper-net \
        -v "$LOCAL_INPUT_DIR/$fname:/app/input/$fname" \
        -v "$SCRAPER_DIR/output:/app/output" \
        -v "$SCRAPER_DIR/logs:/app/logs" \
        -e "INPUT_FILE=/app/input/$fname" \
        -e "OUTPUT_DIR=/app/output" \
        -e "S3_BUCKET=$S3_BUCKET" \
        -e "S3_OUTPUT_PREFIX=$S3_OUTPUT_PREFIX" \
        -e "AWS_REGION=$AWS_REGION" \
        -e "AWS_DEFAULT_REGION=$AWS_REGION" \
        -e "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
        -e "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
        -e "AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN" \
        -e "SERVER_ID=$SERVER_ID" \
        -e "SELENIUM_HUB_URL=http://selenium_${SAFE}:4444/wd/hub" \
        scraper-image

    EXIT_CODE=$(docker inspect "scraper_${SAFE}" --format='{{.State.ExitCode}}')

    if [ "$EXIT_CODE" = "0" ]; then
        echo "[OK] SUCCESS: $fname"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "[ERROR] FAILED: $fname (exit code: $EXIT_CODE)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        # Write to error.log — instance-agent /error-log reads this file
        {
            echo "=== $(date) — FAILED: $fname (exit $EXIT_CODE) ==="
            docker logs "scraper_${SAFE}" 2>&1 | tail -50
            echo ""
        } >> "$SCRAPER_DIR/error.log"
        docker logs "scraper_${SAFE}" >> "$SCRAPER_DIR/logs/${SAFE}_docker.log" 2>&1 || true
    fi

    docker rm -f "scraper_${SAFE}" "selenium_${SAFE}" >/dev/null 2>&1 || true

done < /tmp/my_files.txt

echo ""
echo "=========================================="
echo "DONE — Success=$SUCCESS_COUNT  Failed=$FAIL_COUNT"
echo "=========================================="

# ── Write final status — instance-agent /status reads this ───────────────────
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "STATUS=success" > "$SCRAPER_DIR/status.txt"
else
    echo "STATUS=error" > "$SCRAPER_DIR/status.txt"
fi

# ── Upload run log to S3 ──────────────────────────────────────────────────────
aws s3 cp "$LOG_FILE" \
    "s3://$S3_BUCKET/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/trigger_$(date +%Y%m%d_%H%M%S).log" \
    --region "$AWS_REGION" || true

# ── SNS notification ──────────────────────────────────────────────────────────
MY_FILES_LIST=$(tr '\n' ' ' < /tmp/my_files.txt)

if [ "$FAIL_COUNT" -eq 0 ]; then
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID SUCCESS"
    MESSAGE="All files OK: $MY_FILES_LIST"
else
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID PARTIAL FAILURE"
    MESSAGE="Success=$SUCCESS_COUNT Failed=$FAIL_COUNT | Files: $MY_FILES_LIST"
fi

aws sns publish \
    --topic-arn "$SNS_TOPIC_ARN" \
    --subject "$SUBJECT" \
    --message "$MESSAGE" \
    --region "$AWS_REGION" || true
