#!/bin/bash
# ============================================================
# trigger.sh — Re-run the full scraper without destroying the server
#
# When to use:
#   - Scraper failed on one file and you want to retry
#   - You updated scraper.py on GitHub and want to re-run
#   - Any issue that doesn't need a new server
#
# What it does:
#   1. Refreshes IAM credentials (they expire every few hours)
#   2. Pulls latest code from GitHub
#   3. Re-reads S3 file list and assigns same slice to this server
#   4. Re-downloads input files
#   5. Rebuilds Docker image
#   6. Processes files sequentially with noVNC viewable on port 7900
#   7. Sends SNS notification
#
# Run it: sudo bash /home/ubuntu/trigger.sh
#
# Watch Chrome live while it runs:
#   Open in browser: http://YOUR_EC2_IP:7900/?autoconnect=1&resize=scale&password=secret
# ============================================================
set -e

echo "=========================================="
echo "TRIGGER.SH — $(date)"
echo "=========================================="

cd /home/ubuntu/scraper

# ── Load persistent config saved by user-data.sh ─────────────────────────────
if [ ! -f /home/ubuntu/scraper/.env ]; then
    echo "ERROR: .env file not found. Was user-data.sh run successfully?"
    exit 1
fi
source /home/ubuntu/scraper/.env

echo "Server ID    : $SERVER_ID"
echo "Region       : $AWS_REGION"
echo "Files/server : $FILES_PER_SERVER"
echo ""

# ── Clean up previous run ─────────────────────────────────────────────────────
echo "Cleaning up previous containers..."
docker rm -f $(docker ps -aq --filter "name=scraper_")  2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=selenium_") 2>/dev/null || true
rm -f output/*.xlsx logs/*.log

# ── Refresh IAM credentials ───────────────────────────────────────────────────
# IAM credentials from instance metadata expire — always refresh before running
echo "Refreshing IAM credentials..."
ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
CREDS=$(curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$CREDS"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Token'])")
echo "Credentials refreshed."

# ── Pull latest code from GitHub ──────────────────────────────────────────────
echo "Pulling latest code..."
cd ./repo
git pull origin "$GITHUB_BRANCH" || echo "Git pull failed — continuing with current code"
cd ..

# ── Rebuild Docker image with latest code ────────────────────────────────────
docker build -t scraper-image ./repo
echo "Docker image rebuilt."

# ── Re-fetch S3 file list and assign same slice ───────────────────────────────
# S3 files are NEVER deleted — this always gives the same result
# Server 0 always gets files 0-1, Server 1 always gets files 2-3, etc.
echo "Fetching S3 file list..."
aws s3 ls "s3://$S3_BUCKET/$S3_INPUT_PREFIX" --region "$AWS_REGION" \
    | awk '{print $4}' | grep '\.xlsx$' | sort > /tmp/all_files.txt
echo "All S3 files:"; cat /tmp/all_files.txt

python3 - << PYEOF
server_id        = int("$SERVER_ID")
files_per_server = int("$FILES_PER_SERVER")

with open('/tmp/all_files.txt') as f:
    all_files = [l.strip() for l in f if l.strip()]

start_idx = server_id * files_per_server
end_idx   = start_idx + files_per_server
my_files  = all_files[start_idx:end_idx]

print(f"Server {server_id}: slice [{start_idx}:{end_idx}] = {my_files}")

with open('/tmp/my_files.txt', 'w') as f:
    f.write('\n'.join(my_files) + ('\n' if my_files else ''))
PYEOF

echo "My files:"; cat /tmp/my_files.txt

# ── Re-download input files ───────────────────────────────────────────────────
rm -f input/*.xlsx
while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    echo "  Downloading: $fname"
    aws s3 cp "s3://$S3_BUCKET/$S3_INPUT_PREFIX$fname" \
        "/home/ubuntu/scraper/input/$fname" --region "$AWS_REGION"
done < /tmp/my_files.txt

# ── Process files sequentially ───────────────────────────────────────────────
FILE_COUNT=$(grep -c . /tmp/my_files.txt 2>/dev/null || echo 0)

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "No files assigned. Nothing to do."
    exit 0
fi

echo ""
echo "=============================="
echo "Processing $FILE_COUNT file(s)..."
echo "Watch Chrome live in your browser:"
echo "  http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):7900/?autoconnect=1&resize=scale&password=secret"
echo "=============================="

SUCCESS_COUNT=0; FAIL_COUNT=0; FILE_NUM=0

while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    FILE_NUM=$((FILE_NUM + 1))
    echo ""
    echo "--- File $FILE_NUM / $FILE_COUNT: $fname ---"

    SAFE=$(echo "$fname" | python3 -c \
        "import sys; s=sys.stdin.read().strip(); print(s.replace('.','_').replace('-','_').replace(' ','_').lower())")

    # Start Selenium with noVNC on port 7900
    docker run -d \
        --name "selenium_${SAFE}" \
        --shm-size="2g" \
        -p 4444:4444 \
        -p 7900:7900 \
        -e SE_NODE_MAX_SESSIONS=1 \
        -e SE_SESSION_REQUEST_TIMEOUT=300 \
        -e SE_VNC_NO_PASSWORD=1 \
        selenium/standalone-chrome:latest

    echo "  Waiting for Selenium..."
    for i in $(seq 1 30); do
        docker exec "selenium_${SAFE}" curl -sf http://localhost:4444/wd/hub/status \
            > /dev/null 2>&1 && echo "  Selenium ready (attempt $i)" && break
        sleep 2
    done

    docker run --name "scraper_${SAFE}" \
        --link "selenium_${SAFE}:selenium-chrome" \
        -v "/home/ubuntu/scraper/input/$fname:/app/input/$fname" \
        -v "/home/ubuntu/scraper/output:/app/output" \
        -v "/home/ubuntu/scraper/logs:/app/logs" \
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
        -e "SELENIUM_HUB_URL=http://selenium-chrome:4444/wd/hub" \
        scraper-image

    EXIT_CODE=$(docker inspect "scraper_${SAFE}" --format='{{.State.ExitCode}}')
    if [ "$EXIT_CODE" = "0" ]; then
        echo "  SUCCESS: $fname"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  FAILED: $fname (exit: $EXIT_CODE)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        docker logs "scraper_${SAFE}" >> "/home/ubuntu/scraper/logs/${SAFE}_docker.log" 2>&1 || true
    fi

    docker rm -f "scraper_${SAFE}" "selenium_${SAFE}" 2>/dev/null || true

done < /tmp/my_files.txt

echo ""
echo "=============================="
echo "DONE — Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT"
echo "=============================="

# SNS notification
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
