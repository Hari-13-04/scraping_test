#!/bin/bash
# ============================================================
# trigger.sh — Re-run scraper using already assigned input
# ============================================================

set -e

echo "=========================================="
echo "TRIGGER.SH — $(date)"
echo "=========================================="

cd /home/ubuntu/scraper

# ── Load config ─────────────────────────────────────────────
if [ ! -f /home/ubuntu/scraper/.env ]; then
    echo "ERROR: .env not found"
    exit 1
fi
source /home/ubuntu/scraper/.env

echo "Server ID : $SERVER_ID"
echo "Region    : $AWS_REGION"
echo ""

# ── Cleanup previous containers ─────────────────────────────
echo "Cleaning old containers..."
docker rm -f $(docker ps -aq --filter "name=scraper_")  2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=selenium_") 2>/dev/null || true

rm -f output/*.xlsx logs/*.log

# ── Refresh IAM creds (HOST only: SNS etc) ──────────────────
echo "Refreshing IAM credentials..."
ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
CREDS=$(curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")

export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Token'])")

echo "Credentials refreshed."

# ── Pull latest code ────────────────────────────────────────
echo "Pulling latest GitHub code..."
cd ./repo
git pull origin "$GITHUB_BRANCH" || echo "Git pull failed — using existing code"
cd ..

# ── Build Docker image ──────────────────────────────────────
echo "Building Docker image..."
docker build -t scraper-image ./repo

# ── Use local assigned input ────────────────────────────────
LOCAL_INPUT_DIR="/home/ubuntu/scraper/input"

echo ""
echo "Using already assigned input files:"
echo "$LOCAL_INPUT_DIR"

ls "$LOCAL_INPUT_DIR"/*.xlsx 2>/dev/null \
    | xargs -n1 basename \
    | sort > /tmp/my_files.txt || true

FILE_COUNT=$(grep -c . /tmp/my_files.txt 2>/dev/null || echo 0)

echo "Files on this server:"
cat /tmp/my_files.txt || true

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "No input files found — nothing to process."
    exit 0
fi

# ── Processing loop ────────────────────────────────────────
echo ""
echo "=============================="
echo "Processing $FILE_COUNT file(s)..."
echo "Watch Chrome live:"
echo "http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):7900/?autoconnect=1&resize=scale&password=secret"
echo "=============================="

SUCCESS_COUNT=0
FAIL_COUNT=0
FILE_NUM=0

while IFS= read -r fname; do
    [ -z "$fname" ] && continue

    FILE_NUM=$((FILE_NUM + 1))
    echo ""
    echo "--- File $FILE_NUM / $FILE_COUNT: $fname ---"

    SAFE=$(echo "$fname" | python3 -c \
        "import sys; s=sys.stdin.read().strip(); print(s.replace('.','_').replace('-','_').replace(' ','_').lower())")

    # Start Selenium
    docker run -d \
        --name "selenium_${SAFE}" \
        --shm-size="2g" \
        -p 4444:4444 \
        -p 7900:7900 \
        -e SE_NODE_MAX_SESSIONS=1 \
        -e SE_SESSION_REQUEST_TIMEOUT=300 \
        -e SE_VNC_NO_PASSWORD=1 \
        selenium/standalone-chrome:latest

    echo "Waiting for Selenium..."
    for i in $(seq 1 30); do
        docker exec "selenium_${SAFE}" curl -sf http://localhost:4444/wd/hub/status \
            > /dev/null 2>&1 && echo "Selenium ready (attempt $i)" && break
        sleep 2
    done

    # Run scraper (IAM role via metadata)
    docker run --name "scraper_${SAFE}" \
        --link "selenium_${SAFE}:selenium-chrome" \
        --network host \
        -v "/home/ubuntu/scraper/input/$fname:/app/input/$fname" \
        -v "/home/ubuntu/scraper/output:/app/output" \
        -v "/home/ubuntu/scraper/logs:/app/logs" \
        -e "INPUT_FILE=/app/input/$fname" \
        -e "OUTPUT_DIR=/app/output" \
        -e "S3_BUCKET=$S3_BUCKET" \
        -e "S3_OUTPUT_PREFIX=$S3_OUTPUT_PREFIX" \
        -e "AWS_REGION=$AWS_REGION" \
        -e "AWS_DEFAULT_REGION=$AWS_REGION" \
        -e "SERVER_ID=$SERVER_ID" \
        -e "SELENIUM_HUB_URL=http://selenium-chrome:4444/wd/hub" \
        scraper-image

    EXIT_CODE=$(docker inspect "scraper_${SAFE}" --format='{{.State.ExitCode}}')

    if [ "$EXIT_CODE" = "0" ]; then
        echo "SUCCESS: $fname"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "FAILED: $fname (exit: $EXIT_CODE)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        docker logs "scraper_${SAFE}" >> "/home/ubuntu/scraper/logs/${SAFE}_docker.log" 2>&1 || true
    fi

    docker rm -f "scraper_${SAFE}" "selenium_${SAFE}" 2>/dev/null || true

done < /tmp/my_files.txt

echo ""
echo "=============================="
echo "DONE — Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT"
echo "=============================="

# ── SNS notify (host IAM creds) ─────────────────────────────
MY_FILES_LIST=$(cat /tmp/my_files.txt | tr '\n' ' ')

if [ "$FAIL_COUNT" -eq 0 ]; then
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID - SUCCESS (trigger)"
    MESSAGE="trigger.sh complete. Success=$SUCCESS_COUNT | Files: $MY_FILES_LIST"
else
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID - PARTIAL FAILURE (trigger)"
    MESSAGE="trigger.sh: Success=$SUCCESS_COUNT Failed=$FAIL_COUNT | Files: $MY_FILES_LIST"
fi

aws sns publish \
    --topic-arn "$SNS_TOPIC_ARN" \
    --subject "$SUBJECT" \
    --message "$MESSAGE" \
    --region "$AWS_REGION" || true