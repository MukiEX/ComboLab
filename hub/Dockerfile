# Build from the repository root:  docker build -f hub/Dockerfile -t combolab-hub .
FROM python:3.12-slim
WORKDIR /app
COPY hub/combolab_hub.py hub/hub_auth.py hub/hub.html reframework/data/ComboLab/combolab_merge.py ./
ENV COMBOLAB_HUB_DATA=/data COMBOLAB_HUB_HOST=0.0.0.0 COMBOLAB_HUB_PORT=8770 PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 8770
HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8770/healthz')" || exit 1
ENTRYPOINT ["python", "/app/combolab_hub.py"]
CMD ["serve"]
