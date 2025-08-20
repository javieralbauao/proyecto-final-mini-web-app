FROM python:3.11-slim

# System deps for mysqlclient / Flask-MySQLdb
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential default-libmysqlclient-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Workdir
WORKDIR /app

# Requirements first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code
COPY . .

# Expose Flask port
EXPOSE 5000

# Run with gunicorn (module 'web.views' exposes 'app')
CMD ["gunicorn", "-b", "0.0.0.0:5000", "web.views:app"]
