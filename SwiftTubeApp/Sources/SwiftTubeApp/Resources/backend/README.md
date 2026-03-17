# SwiftTube Backend

## Setup

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
uvicorn app.main:app --reload --host 127.0.0.1 --port 4891
```

## Endpoints

- `GET /health`
- `GET /recommendations` (optional `?continuation=`)
- `GET /video/{video_id}`
