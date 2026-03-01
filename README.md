# API Backend

This is a standalone Express.js backend API for tenant management operations that require Node.js runtime (not compatible with Edge Runtime).

## Setup

1. Install dependencies:
```bash
npm install
```

2. Set up environment variables in `.env`:
```
NEXT_PUBLIC_SUPABASE_MIDDLEWARE_URL=your_middleware_supabase_url
SUPABASE_MIDDLEWARE_SERVICE_ROLE_KEY=your_service_role_key
NEXT_PUBLIC_SUPABASE_MIDDLEWARE_ANON_KEY=your_anon_key (optional, falls back to service role key)
SUPABASE_ACCESS_TOKEN=your_supabase_access_token
SUPABASE_ORG_ID=your_org_id
PORT=3001 (optional, defaults to 3001)
```

3. Run the server:
```bash
npm start
```

For development with auto-reload:
```bash
npm run dev
```

## API Endpoints

### POST /api/take-live
Takes a tenant live by creating a Supabase project, pushing schema, and migrating data.

**Headers:**
- `Cookie: admin_session=<session_token>`

**Body:**
```json
{
  "tenantId": "tenant-uuid"
}
```

### POST /api/fetch-data
Fetches tenant data from middleware database and pushes it to tenant database.

**Headers:**
- `Cookie: admin_session=<session_token>`

**Body:**
```json
{
  "tenantId": "tenant-uuid"
}
```

### GET /health
Health check endpoint.

## Deployment

This backend is designed to be deployed on Railway or similar Node.js hosting platforms.

1. Create a new Railway project
2. Connect your GitHub repository
3. Set environment variables in Railway dashboard
4. Deploy

The server will be available at the Railway-provided HTTPS URL.
