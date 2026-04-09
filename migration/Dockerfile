FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY import_ch_export.py .

ENTRYPOINT ["python", "import_ch_export.py"]
