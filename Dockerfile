FROM seleniumbase/seleniumbase

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY scraper.py .
COPY entrypoint.sh /entrypoint.sh

# 🔧 REMOVE non-ASCII characters from scraper.py
RUN sed -i 's/[^\x00-\x7F]//g' /app/scraper.py


RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]