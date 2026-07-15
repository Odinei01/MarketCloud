FROM python:3.11-slim
WORKDIR /app
COPY workers/modeling-worker/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY workers/modeling-worker/ .
COPY workers/ml-worker/marketcloud_ml_worker_hourly_real_v2.py ./marketcloud_ml_worker_hourly_real_v2.py
COPY workers/ml-worker/marketcloud_ml_worker_hourly_target_real_v3.py ./marketcloud_ml_worker_hourly_target_real_v3.py
CMD ["python", "-u", "main.py"]
