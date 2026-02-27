FROM mcr.microsoft.com/playwright/python:v1.58.0-jammy

WORKDIR /app

# ---- System deps (Chrome / Selenium / Playwright) ----
RUN apt-get update && apt-get install -y \
    xvfb \
    curl \
    unzip \
    wget \
    fonts-liberation \
    libglib2.0-0 \
    libnss3 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libxshmfence1 \
    libx11-xcb1 \
    libxext6 \
    libxfixes3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---- Python deps ----
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir \
        playwright-stealth \
        selenium-stealth \
        undetected-chromedriver

# ---- Ensure Playwright browsers present ----
RUN playwright install --with-deps chromium

# ---- SeleniumBase driver (optional but ok) ----
RUN seleniumbase install chromedriver

# ---- AWS CLI v2 ----
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# ---- App ----
COPY scraper.py .
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PYTHONUNBUFFERED=1
ENV DISPLAY=:99

CMD ["/entrypoint.sh"]