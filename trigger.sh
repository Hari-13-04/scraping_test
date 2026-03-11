#!/bin/bash
# =============================================================================
#  trigger.sh
#  Location : /home/ubuntu/trigger.sh
#  Called by: instance-agent POST /trigger  (dashboard → Restart button)
#             or manually: sudo bash /home/ubuntu/trigger.sh
#
#  Changes from original:
#    + Writes status.txt (RUNNING → SUCCESS or ERROR)
#    + Creates timestamped run log + latest.log symlink
#    + Appends to error.log on failure
#    + Uses --network scraper-net instead of --link (more reliable)
# =============================================================================

set -e

SCRAPER_DIR="/home/ubuntu/scraper"
STATUS_FILE="$SCRAPER_DIR/status.txt"
ERROR_LOG="$SCRAPER_DIR/error.log"
LOGS_DIR="$SCRAPER_DIR/logs"

# ── Create timestamped run log ────────────────────────────────────────────────
mkdir -p "$LOGS_DIR" "$SCRAPER_DIR/output"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RUN_LOG="$LOGS_DIR/run_${TIMESTAMP}.log"

# latest.log symlink — dashboard Live Log always tails this file
ln -sf "$RUN_LOG" "$LOGS_DIR/latest.log"

# All stdout/stderr goes to run log AND stdout (agent streams stdout to dashboard)
exec > >(tee -a "$RUN_LOG") 2>&1

echo "=========================================="
echo "TRIGGER.SH — $(date)"
echo "Run log : $RUN_LOG"
echo "=========================================="

# ── Mark RUNNING immediately ──────────────────────────────────────────────────
echo "STATUS=RUNNING" > "$STATUS_FILE"
echo "[INFO] Status → RUNNING"

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ ! -f "$SCRAPER_DIR/.env" ]; then
    echo "[ERROR] .env not found at $SCRAPER_DIR/.env"
    echo "STATUS=ERROR" > "$STATUS_FILE"
    exit 1
fi
source "$SCRAPER_DIR/.env"

echo "[INFO] Server   : $SERVER_ID"
echo "[INFO] Region   : $AWS_REGION"
echo "[INFO] Project  : $PROJECT_NAME"

# ── Cleanup previous containers ───────────────────────────────────────────────
echo "[INFO] Cleaning up old containers..."
docker rm -f $(docker ps -aq --filter "name=scraper_")  2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=selenium_") 2>/dev/null || true
docker network rm scraper-net 2>/dev/null || true
rm -f "$SCRAPER_DIR/output"/*.xlsx

# ── Refresh IAM credentials ───────────────────────────────────────────────────
echo "[INFO] Refreshing IAM credentials..."
ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
CREDS=$(curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | python3 -c "import sys,json;print(json.load(sys.stdin)['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | python3 -c "import sys,json;print(json.load(sys.stdin)['Token'])")
echo "[INFO] IAM credentials refreshed"

# ── Git pull latest code ──────────────────────────────────────────────────────
echo "[INFO] Pulling latest code from branch: $GITHUB_BRANCH"
cd "$SCRAPER_DIR/repo"
git pull origin "$GITHUB_BRANCH" || echo "[WARN] git pull failed — using existing code"
cd "$SCRAPER_DIR"

# ── Build Docker image ────────────────────────────────────────────────────────
echo "[INFO] Building Docker image..."
docker build -t scraper-image "$SCRAPER_DIR/repo"
echo "[INFO] Docker image built"

# ── Create network ────────────────────────────────────────────────────────────
docker network create scraper-net

# ── Determine assigned files ──────────────────────────────────────────────────
echo "[INFO] Listing S3 input files..."
aws s3 ls "s3://$S3_BUCKET/$S3_INPUT_PREFIX" --region "$AWS_REGION" \
    | awk '{print $4}' | grep '\.xlsx$' | sort > /tmp/all_files.txt

# Same round-robin math as user-data.sh — always same files assigned
python3 - << PYEOF
server_id     = int("$SERVER_ID")
total_servers = int("${TOTAL_SERVERS:-1}")

with open('/tmp/all_files.txt') as f:
    all_files = [l.strip() for l in f if l.strip()]

my_files = [f for i, f in enumerate(all_files) if i % total_servers == server_id]
print(f"[INFO] Server {server_id}: total={len(all_files)} assigned={len(my_files)} files={my_files}")

with open('/tmp/my_files.txt', 'w') as f:
    f.write('\n'.join(my_files) + ('\n' if my_files else ''))
PYEOF

# Download any missing input files
while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    if [ ! -f "$SCRAPER_DIR/input/$fname" ]; then
        echo "[INFO] Downloading: $fname"
        aws s3 cp "s3://$S3_BUCKET/$S3_INPUT_PREFIX$fname" \
            "$SCRAPER_DIR/input/$fname" --region "$AWS_REGION"
    else
        echo "[INFO] Using cached: $fname"
    fi
done < /tmp/my_files.txt

FILE_COUNT=$(grep -c . /tmp/my_files.txt 2>/dev/null || echo 0)
echo "[INFO] Files to process: $FILE_COUNT"

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "[WARN] No files assigned to server $SERVER_ID"
    echo "STATUS=SUCCESS" > "$STATUS_FILE"
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

    SAFE=$(echo "$fname" | python3 -c \
        "import sys; s=sys.stdin.read().strip(); print(s.replace('.','_').replace('-','_').replace(' ','_').lower())")

    # ── Start Selenium ──────────────────────────────────────────────────
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

    # ── Run scraper ─────────────────────────────────────────────────────
    docker run --name "scraper_${SAFE}" \
        --network scraper-net \
        -v "$SCRAPER_DIR/input/$fname:/app/input/$fname" \
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
        echo "[ERROR] FAILED: $fname (exit: $EXIT_CODE)"
        FAIL_COUNT=$((FAIL_COUNT + 1))

        # Save full docker logs for this failed container
        docker logs "scraper_${SAFE}" >> "$LOGS_DIR/${SAFE}_docker.log" 2>&1 || true

        # Append summary to error.log — dashboard Error Log button reads this
        {
            echo ""
            echo "=== $(date '+%Y-%m-%d %H:%M:%S') === File: $fname | Exit: $EXIT_CODE ==="
            echo "Run log: $RUN_LOG"
            docker logs "scraper_${SAFE}" 2>&1 | tail -30
        } >> "$ERROR_LOG"
    fi

    docker rm -f "scraper_${SAFE}" "selenium_${SAFE}" 2>/dev/null || true

done < /tmp/my_files.txt

# ── Final status ──────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "ALL DONE — Success=$SUCCESS_COUNT  Failed=$FAIL_COUNT"
echo "=========================================="

MY_FILES_LIST=$(tr '\n' ' ' < /tmp/my_files.txt)

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "STATUS=SUCCESS" > "$STATUS_FILE"
    echo "[OK] All files processed successfully"
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID SUCCESS"
    MESSAGE="All files OK. Success=$SUCCESS_COUNT | Files: $MY_FILES_LIST"
else
    echo "STATUS=ERROR" > "$STATUS_FILE"
    echo "[ERROR] $FAIL_COUNT file(s) failed — check Error Log in dashboard"
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID PARTIAL FAILURE"
    MESSAGE="Success=$SUCCESS_COUNT Failed=$FAIL_COUNT | Files: $MY_FILES_LIST"
fi

# ── Upload run log to S3 ──────────────────────────────────────────────────────
aws s3 cp "$RUN_LOG" \
    "s3://$S3_BUCKET/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/run_${TIMESTAMP}.log" \
    --region "$AWS_REGION" || true

# ── SNS notification ──────────────────────────────────────────────────────────
aws sns publish \
    --topic-arn "$SNS_TOPIC_ARN" \
    --subject "$SUBJECT" \
    --message "$MESSAGE" \
    --region "$AWS_REGION" || true

echo "[INFO] trigger.sh complete"
