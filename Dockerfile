FROM mcr.microsoft.com/playwright/python:v1.46.0-jammy

WORKDIR /app

# ---- Install SeleniumBase + deps ----
RUN apt-get update && apt-get install -y \
    curl unzip xvfb wget \
    && rm -rf /var/lib/apt/lists/*

# ---- Python deps ----
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- Install SeleniumBase drivers ----
RUN seleniumbase install chromedriver

RUN playwright install chromium
# ---- Install AWS CLI v2 ----
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# ---- Copy scraper ----
COPY scraper.py .
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]