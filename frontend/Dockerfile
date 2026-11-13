FROM python:3.13.17-slim

WORKDIR /app
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements-dev.txt

COPY . .

RUN useradd --create-home --uid 10001 web
USER web

ENV FLASK_HOST=0.0.0.0 FLASK_PORT=5000
EXPOSE 5000
CMD ["python", "app.py"]
