FROM python:3.11-slim-bookworm

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Bootstrap downloads the necessary auto-instrumentation hooks (e.g. for FastAPI)
RUN opentelemetry-bootstrap -a install

COPY . .

EXPOSE 8001

# Run the app wrapped with the OTel CLI agent
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
