#!/bin/bash
# ============================================================
# [user-data.sh](http://user-data.sh) — Runs on EC2 Linux at first boot
# Terraform pastes this content into EC2 user_data AFTER the
# "cat > /tmp/tf_vars.env" block in [main.tf](http://main.tf)
# ============================================================
set -e
SCRAPER_DIR="/home/ubuntu/scraper"
AGENT_DIR="/home/ubuntu/agent"

# Ensure log directory exists before redirect
mkdir -p "$SCRAPER_DIR"/logs
touch "$SCRAPER_DIR"/logs/main.log

# ── Source all Terraform vars injected by [main.tf](http://main.tf) ────────────────────────────
source /tmp/tf_vars.env
SERVER_ID="$TF_SERVER_ID"
TOTAL_SERVERS="$TF_TOTAL_SERVERS"
S3_BUCKET="$TF_S3_BUCKET"
S3_INPUT_PREFIX="$TF_S3_INPUT_PREFIX"
S3_OUTPUT_PREFIX="$TF_S3_OUTPUT_PREFIX"
AWS_REGION="$TF_AWS_REGION"
SNS_TOPIC_ARN="$TF_SNS_TOPIC_ARN"
PROJECT_NAME="$TF_PROJECT_NAME"
GITHUB_REPO="$TF_GITHUB_REPO"
GITHUB_BRANCH="$TF_GITHUB_BRANCH"
GITHUB_TOKEN="$TF_GITHUB_TOKEN"
AUTO_TERMINATE="$TF_AUTO_TERMINATE"
FILES_PER_SERVER="$TF_FILES_PER_SERVER"
AGENT_TOKEN="$TF_AGENT_TOKEN"
AGENT_PORT="$TF_AGENT_PORT"

echo "=========================================="
echo "SCRAPER SETUP — $(date)"
echo "=========================================="
echo "Server ID    : $SERVER_ID / $TOTAL_SERVERS"
echo "Region       : $AWS_REGION"
echo "Files/server : $FILES_PER_SERVER"
echo "S3 bucket    : $S3_BUCKET"
echo "Agent port   : $AGENT_PORT"

if [ -z "$SERVER_ID" ] || [ -z "$FILES_PER_SERVER" ]; then
    echo "ERROR: SERVER_ID or FILES_PER_SERVER is empty!"
    cat /tmp/tf_vars.env
    exit 1
fi

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# ── Install system packages ───────────────────────────────────────────────────
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    docker.io git awscli curl python3 python3-boto3 jq nodejs npm
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# ── Create scraper directory structure ───────────────────────────────────────
mkdir -p "$SCRAPER_DIR"/{input,output,logs}
mkdir -p "$AGENT_DIR"
touch "$SCRAPER_DIR"/logs/main.log
touch "$SCRAPER_DIR"/status.txt
chown -R ubuntu:ubuntu "$SCRAPER_DIR"
chmod 664 "$SCRAPER_DIR"/status.txt
cd "$SCRAPER_DIR"
sudo chmod 666 status.txt

# ── Install + start instance-agent.js ────────────────────────────────────────
# instance-agent.js is stored in S3 and downloaded at boot time.
# This keeps [user-data.sh](http://user-data.sh) well under the 16KB AWS limit.
# Terraform uploads instance-agent.js to S3 before EC2s are created (see [main.tf](http://main.tf)).
mkdir -p "$AGENT_DIR"
echo "Downloading instance-agent.js from S3..."
aws s3 cp "s3://$S3_BUCKET/agent/instance-agent.js" "$AGENT_DIR/instance-agent.js" \
    --region "us-east-1" \
    || { echo "ERROR: Failed to download instance-agent.js from s3://$S3_BUCKET/agent/instance-agent.js"; exit 1; }

chmod +x "$AGENT_DIR/instance-agent.js"
chown -R ubuntu:ubuntu "$AGENT_DIR"

# Write systemd service — injects AGENT_TOKEN and AGENT_PORT from terraform vars
cat > /etc/systemd/system/instance-agent.service << SVCEOF
[Unit]
Description=Instance Agent (Live Log / Error Log / Restart)
After=network.target
[Service]
Type=simple
User=ubuntu
WorkingDirectory=${AGENT_DIR}
ExecStart=/usr/bin/node ${AGENT_DIR}/instance-agent.js
Restart=always
RestartSec=5
# ── These are the critical env vars — set by Terraform at launch time ──
Environment=AGENT_TOKEN=${AGENT_TOKEN}
Environment=AGENT_PORT=${AGENT_PORT}
Environment=SCRAPER_DIR=${SCRAPER_DIR}
[Install]
WantedBy=multi-user.target
SVCEOF

chown -R ubuntu:ubuntu "$SCRAPER_DIR"
systemctl daemon-reload
systemctl enable instance-agent
systemctl start instance-agent

echo "instance-agent started on port $AGENT_PORT (auth: $([ -n "$AGENT_TOKEN" ] && echo 'enabled' || echo 'disabled'))"

# ── Open agent port in UFW firewall if active ─────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${AGENT_PORT}/tcp" comment "instance-agent" || true
fi

# ── Clone repo (GitHub or GitLab) ────────────────────────────────────────────
echo "Cloning repo..."
if [[ -z "${GITHUB_REPO:-}" ]]; then
    echo "STATUS=error" > "$SCRAPER_DIR"/status.txt
    echo "GITHUB_REPO is empty"
fi

# Detect GitLab by URL containing "gitlab" OR token starting with "glpat-"
is_gitlab() {
    echo "$GITHUB_REPO" | grep -qi "gitlab" || echo "$GITHUB_TOKEN" | grep -q "^glpat-"
}

# Convert SSH URL to HTTPS if needed
if echo "$GITHUB_REPO" | grep -q "^git@"; then
    if is_gitlab; then
        GITHUB_REPO=$(echo "$GITHUB_REPO" | sed "[s|git@gitlab.com](mailto:s|git@gitlab.com):|https://gitlab.com/|")
    else
        GITHUB_REPO=$(echo "$GITHUB_REPO" | sed "[s|git@github.com](mailto:s|git@github.com):|https://github.com/|")
    fi
fi
if [ -n "$GITHUB_TOKEN" ]; then
    if is_gitlab; then
        # GitLab PAT requires "oauth2:<token>@"
        REPO_URL=$(echo "$GITHUB_REPO" | sed "s|https://|https://oauth2:$GITHUB_TOKEN@|")
    else
        # GitHub PAT — token only, no username needed
        REPO_URL=$(echo "$GITHUB_REPO" | sed "s|https://|https://$GITHUB_TOKEN@|")
    fi
else
    REPO_URL="$GITHUB_REPO"
fi
echo "Cloning from: $(echo "$REPO_URL" | sed 's|oauth2:[^@]*@|oauth2:***@|;s|https://[^@]*@|https://***@|')"
git clone -b "$GITHUB_BRANCH" "$REPO_URL" ./repo
echo "Repo contents:"; ls -la ./repo/
chmod +x ./repo/[entrypoint.sh](http://entrypoint.sh)
chmod +x ./repo/[trigger.sh](http://trigger.sh) 2>/dev/null || true

# ── Save persistent .env for [trigger.sh](http://trigger.sh) and instance-agent ───────────────────
cat > "$SCRAPER_DIR"/.env << ENVEOF
S3_BUCKET=$S3_BUCKET
S3_INPUT_PREFIX=$S3_INPUT_PREFIX
S3_OUTPUT_PREFIX=$S3_OUTPUT_PREFIX
AWS_REGION=$AWS_REGION
SERVER_ID=$SERVER_ID
FILES_PER_SERVER=$FILES_PER_SERVER
SNS_TOPIC_ARN=$SNS_TOPIC_ARN
PROJECT_NAME=$PROJECT_NAME
GITHUB_REPO=$GITHUB_REPO
GITHUB_BRANCH=$GITHUB_BRANCH
GITHUB_TOKEN=$GITHUB_TOKEN
AUTO_TERMINATE=$AUTO_TERMINATE
AGENT_TOKEN=$AGENT_TOKEN
AGENT_PORT=$AGENT_PORT
ENVEOF

# chmod 600 /home/ubuntu/scraper/.env
chmod 644 "$SCRAPER_DIR"/.env
chown ubuntu:ubuntu "$SCRAPER_DIR"/.env

# ── Copy [trigger.sh](http://trigger.sh) from repo to scraper dir ─────────────────────────────────
cp ./repo/[trigger.sh](http://trigger.sh) "$SCRAPER_DIR"/[trigger.sh](http://trigger.sh)
chmod +x "$SCRAPER_DIR"/[trigger.sh](http://trigger.sh)
cd "$SCRAPER_DIR"

# ── Fetch IAM credentials from instance metadata ─────────────────────────────
echo "Fetching IAM credentials..."
ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
CREDS=$(curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")
AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")
AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")
AWS_SESSION_TOKEN=$(echo "$CREDS"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Token'])")
echo "Credentials fetched."

# ── List all S3 input files ───────────────────────────────────────────────────
echo "Listing S3 input files..."
aws s3 ls "s3://$S3_BUCKET/$S3_INPUT_PREFIX" --region "$AWS_REGION" \
    | awk '{print $4}' | grep '\.xlsx$' | sort > /tmp/all_files.txt
echo "All S3 files:"; cat /tmp/all_files.txt

# ── Assign this server's file slice ──────────────────────────────────────────
python3 - << PYEOF
server_id     = int("$SERVER_ID")
total_servers = int("$TOTAL_SERVERS")
with open('/tmp/all_files.txt') as f:
    all_files = [l.strip() for l in f if l.strip()]
my_files = [f for i, f in enumerate(all_files) if i % total_servers == server_id]
print(f"Server {server_id}: total={len(all_files)} | assigned={len(my_files)} | files={my_files}")
with open('/tmp/my_files.txt', 'w') as f:
    f.write('\n'.join(my_files) + ('\n' if my_files else ''))
PYEOF

echo "My assigned files:"; cat /tmp/my_files.txt

FILE_COUNT=$(grep -c . /tmp/my_files.txt 2>/dev/null || echo 0)
if [ "$FILE_COUNT" -eq 0 ]; then
    echo "No files assigned to server $SERVER_ID. Exiting."
    echo "STATUS=idle" > "$SCRAPER_DIR"/status.txt
    aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "[$PROJECT_NAME] Server $SERVER_ID - No Files" \
        --message "Server $SERVER_ID had no files assigned." \
        --region "$AWS_REGION" || true
    exit 0
fi

# ── Write initial status ──────────────────────────────────────────────────────
echo "STATUS=running" > "$SCRAPER_DIR"/status.txt

# ── Download assigned input files from S3 ────────────────────────────────────
while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    echo "  Downloading: $fname"
    aws s3 cp "s3://$S3_BUCKET/$S3_INPUT_PREFIX$fname" \
        "$SCRAPER_DIR/input/$fname" --region "$AWS_REGION"
done < /tmp/my_files.txt

# ── Pull Docker images and build scraper ──────────────────────────────────────
docker pull selenium/standalone-chrome:latest
docker pull seleniumbase/seleniumbase
docker pull mcr.microsoft.com/playwright/python:v1.48.0-jammy
docker build -t scraper-image ./repo
echo "Docker images ready."

# ── Process files sequentially ───────────────────────────────────────────────
echo ""
echo "=============================="
echo "STARTING — $FILE_COUNT file(s) on Server $SERVER_ID"
echo "noVNC: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):7900/?autoconnect=1&resize=scale&password=secret"
echo "=============================="
SUCCESS_COUNT=0; FAIL_COUNT=0; FILE_NUM=0

# Create a timestamped log file for this run — instance-agent tails this
LOG_FILE="$SCRAPER_DIR/logs/run_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    FILE_NUM=$((FILE_NUM + 1))
    echo ""
    echo "--- File $FILE_NUM / $FILE_COUNT: $fname ---"
    SAFE=$(echo "$fname" | python3 -c \
        "import sys; s=sys.stdin.read().strip(); print(s.replace('.','_').replace('-','_').replace(' ','_').lower())")
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
        -e "SELENIUM_HUB_URL=http://selenium-chrome:4444/wd/hub" \
        scraper-image
    EXIT_CODE=$(docker inspect "scraper_${SAFE}" --format='{{.State.ExitCode}}')
    if [ "$EXIT_CODE" = "0" ]; then
        echo "  SUCCESS: $fname"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  FAILED: $fname (exit: $EXIT_CODE)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        docker logs "scraper_${SAFE}" >> "$SCRAPER_DIR/logs/${SAFE}_docker.log" 2>&1 || true
        # Append docker error to error.log so Error Log tab shows it
        echo "[$(date)] ERROR in $fname (exit $EXIT_CODE):" >> "$SCRAPER_DIR/error.log"
        docker logs "scraper_${SAFE}" >> "$SCRAPER_DIR/error.log" 2>&1 || true
    fi
    docker rm -f "scraper_${SAFE}" "selenium_${SAFE}" 2>/dev/null || true
done < /tmp/my_files.txt

echo ""
echo "=============================="
echo "ALL DONE — Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT"
echo "=============================="

# ── Write final status ────────────────────────────────────────────────────────
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "STATUS=success" > "$SCRAPER_DIR"/status.txt
else
    echo "STATUS=error" > "$SCRAPER_DIR"/status.txt
fi

# ── Upload logs to S3 ─────────────────────────────────────────────────────────
aws s3 cp /var/log/cloud-init-output.log \
    "s3://$S3_BUCKET/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/cloud-init.log" \
    --region "$AWS_REGION" || true
aws s3 cp "$LOG_FILE" \
    "s3://$S3_BUCKET/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/run.log" \
    --region "$AWS_REGION" || true

# ── SNS notification ──────────────────────────────────────────────────────────
MY_FILES_LIST=$(cat /tmp/my_files.txt | tr '\n' ' ')
if [ "$FAIL_COUNT" -eq 0 ]; then
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID - SUCCESS"
    MESSAGE="Server $SERVER_ID complete. Success=$SUCCESS_COUNT | Files: $MY_FILES_LIST"
else
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID - PARTIAL FAILURE"
    MESSAGE="Server $SERVER_ID: Success=$SUCCESS_COUNT Failed=$FAIL_COUNT | Files: $MY_FILES_LIST"
fi

aws sns publish \
    --topic-arn "$SNS_TOPIC_ARN" \
    --subject "$SUBJECT" \
    --message "$MESSAGE" \
    --region "$AWS_REGION" || true

if [ "$FAIL_COUNT" -eq 0 ]; then
    if [ "$AUTO_TERMINATE" = "true" ]; then
        echo "Terminating instance..."
        echo "Auto-terminating in 60 seconds..."
        echo "STATUS=idle" > "$SCRAPER_DIR"/status.txt
        sleep 60
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    else
        echo "STATUS=idle" > "$SCRAPER_DIR"/status.txt
        echo "Stopping instance..."
        sleep 60
        aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    fi
else
    echo "STATUS=error" > "$SCRAPER_DIR"/status.txt
    echo "Failures occurred — instance will NOT stop"
fi