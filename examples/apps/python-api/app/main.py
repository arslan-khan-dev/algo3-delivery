"""Sample API for templates/dockerfiles/python.Dockerfile."""
import os
from fastapi import FastAPI

app = FastAPI()


@app.get("/healthz")
def healthz():
    return {"status": "ok", "version": os.environ.get("RELEASE_SHA", "")}
