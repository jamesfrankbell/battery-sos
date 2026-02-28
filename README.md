# LocalFlow Workspace

A self-hosted, local-first app that combines:
- Phase 1: task management like Things 3 (capture, assign people, due dates, projects, and Kanban flow)
- Phase 2: document organization like Notion (nested pages, categories, tags, and page editor)

## Why this stack
- No paid services
- No external database
- Runs fully on your machine
- Modular structure for phased expansion
- Remote access support through LAN/VPN

## Run

```bash
npm start
```

Open: `http://127.0.0.1:8787`

## Remote access (private + free)

### Option A: LAN only

```bash
HOST=0.0.0.0 PORT=8787 npm start
```

Then open `http://<your-computer-ip>:8787` from devices on your local network.

### Option B: Private remote over VPN (recommended)
Use Tailscale (free personal tier):
1. Install Tailscale on your computer and remote device.
2. Join both to your Tailnet.
3. Start app with `HOST=0.0.0.0 PORT=8787 npm start`.
4. Open `http://<tailscale-ip>:8787` from remote devices.

## Data location
All app data is stored locally at:
- `data/app-data.json`

## Project structure

- `server/server.js`: HTTP server entrypoint
- `server/router.js`: API + static routing
- `server/store.js`: local JSON persistence and domain logic
- `client/index.html`: single main page UI
- `client/styles.css`: responsive styling
- `client/app.js`: app bootstrap and state wiring
- `client/modules/tasks.js`: Phase 1 task + Kanban module
- `client/modules/documents.js`: Phase 2 nested pages/documents module
- `client/modules/api.js`: frontend API client

## API surface

- `GET /api/state`
- `POST /api/tasks`
- `PATCH /api/tasks/:id`
- `DELETE /api/tasks/:id`
- `POST /api/documents`
- `PATCH /api/documents/:id`
- `DELETE /api/documents/:id`

## Phase expansion ideas
- Auth + per-user workspaces
- File attachments for documents
- Search and backlinks
- Calendar view for tasks
- Offline-first sync with peer devices
