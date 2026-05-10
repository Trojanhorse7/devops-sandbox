FROM python:3.12-alpine

WORKDIR /app

RUN apk add --no-cache procps

ENV PORT=8080
ENV PYTHONUNBUFFERED=1

COPY app.py /app/app.py

EXPOSE 8080

CMD ["python", "/app/app.py"]
