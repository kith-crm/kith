# Kith API Conventions

This document defines the standard conventions for all Kith REST API endpoints. All API
contributors must follow these conventions without exception.

---

## 1. REST Response Envelope

Every API response wraps its payload in a consistent envelope.

### Single Resource

```json
{
  "data": {
    "id": "01J9K2M...",
    "type": "contact",
    "first_name": "Ada",
    "last_name": "Lovelace",
    "inserted_at": "2025-01-15T10:30:00Z",
    "updated_at": "2025-03-01T14:22:00Z"
  },
  "included": []
}
```

### List Resource

```json
{
  "data": [
    { "id": "01J9K2M...", "type": "contact", "first_name": "Ada", ... },
    { "id": "01J9K3N...", "type": "contact", "first_name": "Grace", ... }
  ],
  "meta": {
    "next_cursor": "eyJpZCI6IjAxSjlLM04uLi4ifQ==",
    "has_more": true
  }
}
```

- `data` is always present (object for single, array for list).
- `included` is present only when `?include=` is used (see Section 2).
- `meta` is present on list endpoints and contains pagination info.

---

## 2. Compound Documents (`?include=`)

Related resources can be side-loaded using the `?include=` query parameter.

### Format

```
GET /api/contacts/01J9K2M...?include=notes,tags,addresses
```

Multiple includes are comma-separated. No spaces.

### Included Array Shape

Each item in the top-level `"included"` array carries a `"type"` and `"id"` field so clients
can match it to foreign keys in `"data"`.

```json
{
  "data": {
    "id": "01J9K2M...",
    "type": "contact",
    "first_name": "Ada",
    "tag_ids": ["tag_01", "tag_02"]
  },
  "included": [
    { "type": "tag", "id": "tag_01", "name": "friend" },
    { "type": "tag", "id": "tag_02", "name": "colleague" }
  ]
}
```

### Rules

| Rule | Detail |
|------|--------|
| Depth | One level deep only. `?include=notes.author` is **not** supported. |
| Unknown keys | Return `400 Bad Request` with a Problem Details body listing the unrecognized key(s). |
| No matches | Included array is present but empty: `"included": []`. |
| Per-resource docs | Each resource's API reference documents which include keys it supports. |

---

## 3. Cursor Pagination

All list endpoints use **cursor-based pagination**. Offset pagination is not supported.

### Request

```
GET /api/contacts?cursor=eyJpZCI6IjAxSjlLM04uLi4ifQ==&limit=25
```

| Parameter | Type | Default | Max | Notes |
|-----------|------|---------|-----|-------|
| `cursor` | string | *(omit for first page)* | — | Opaque base64 token; do not parse |
| `limit` | integer | `25` | `100` | Values above 100 return `400` |

### Response Meta

```json
{
  "meta": {
    "next_cursor": "eyJpZCI6IjAxSjlLNE8uLi4ifQ==",
    "has_more": true
  }
}
```

- `next_cursor` is `null` when there are no further pages.
- `has_more` is `false` on the last page.
- Clients **must not** attempt to decode or construct cursor values.

### Empty Results

```json
{
  "data": [],
  "meta": {
    "next_cursor": null,
    "has_more": false
  }
}
```

### First Page

Omit the `cursor` parameter entirely — do not pass an empty string.

---

## 4. RFC 7807 Error Responses

**All errors** use [RFC 7807 Problem Details](https://www.rfc-editor.org/rfc/rfc7807) format.
Plain-text or unstructured error bodies are never returned.

### Content-Type

```
Content-Type: application/problem+json
```

### Shape

```json
{
  "type": "https://kith.app/errors/validation-failed",
  "title": "Validation Failed",
  "status": 422,
  "detail": "First name can't be blank.",
  "errors": [
    { "field": "first_name", "message": "can't be blank" }
  ]
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | URI identifying the error class (may link to documentation) |
| `title` | Yes | Short, human-readable summary (stable per error type) |
| `status` | Yes | Mirrors the HTTP response status code |
| `detail` | Yes | Specific description of this occurrence |
| `errors` | 422 only | Array of per-field validation failures |

### Validation Error (422)

```json
{
  "type": "https://kith.app/errors/validation-failed",
  "title": "Validation Failed",
  "status": 422,
  "detail": "The request body contains validation errors.",
  "errors": [
    { "field": "email", "message": "has invalid format" },
    { "field": "first_name", "message": "can't be blank" }
  ]
}
```

### Unknown Include Key (400)

```json
{
  "type": "https://kith.app/errors/invalid-include",
  "title": "Invalid Include Parameter",
  "status": 400,
  "detail": "Unknown include key: 'foo'. Supported keys for this resource: notes, tags, addresses."
}
```

### Not Found (404)

```json
{
  "type": "https://kith.app/errors/not-found",
  "title": "Not Found",
  "status": 404,
  "detail": "The requested resource does not exist."
}
```

### Rate Limited (429)

```json
{
  "type": "https://kith.app/errors/rate-limit-exceeded",
  "title": "Rate Limit Exceeded",
  "status": 429,
  "detail": "You have exceeded 1000 requests per hour. Try again after the indicated time."
}
```

Response also includes the header: `Retry-After: <seconds>`. The remaining wait is rounded up to whole seconds, with a minimum of one second.

---

## 5. HTTP Status Codes

| Code | Name | When Used |
|------|------|-----------|
| `200` | OK | Successful `GET`, `PUT`, `PATCH` |
| `201` | Created | Successful `POST` that creates a new resource |
| `204` | No Content | Successful `DELETE`, or actions that return no body |
| `400` | Bad Request | Malformed JSON body; unknown `?include=` keys; invalid cursor token; invalid or out-of-range query parameters |
| `401` | Unauthorized | Missing `Authorization` header; invalid or expired Bearer token |
| `403` | Forbidden | Valid authentication but the role/permission is insufficient for the action |
| `404` | Not Found | Resource does not exist **or** belongs to a different account (never `403` for cross-account resources — use `404` to prevent enumeration) |
| `409` | Conflict | Duplicate resource creation (e.g., duplicate tag name, duplicate relationship between the same two contacts) |
| `422` | Unprocessable Entity | Changeset/validation errors; `errors` array included in body |
| `429` | Too Many Requests | Rate limit exceeded; `Retry-After` header required |
| `500` | Internal Server Error | Unexpected server-side failure |
| `501` | Not Implemented | `POST /api/devices` (mobile push notification stub) |

---

## 6. Authentication

### API Pipeline

The API pipeline is separate from the browser/LiveView pipeline and does **not** use or require
CSRF tokens.

### Bearer Token

All protected endpoints require:

```
Authorization: Bearer <token>
```

### Obtaining a Token

```
POST /api/auth/token
Content-Type: application/json

{
  "email": "ada@example.com",
  "password": "hunter2"
}
```

Success response (`200`):

```json
{
  "data": {
    "token": "kith_tok_...",
    "expires_at": "2026-04-17T10:00:00Z"
  }
}
```

### Revoking a Token

```
DELETE /api/auth/token
Authorization: Bearer <token>
```

Returns `204 No Content`.

### Rate Limiting

- **Limit:** 1,000 requests per hour per account.
- **Exceeded:** `429 Too Many Requests` + `Retry-After: <seconds>` header (remaining wait rounded up, minimum one second).

---

## 7. URL Conventions

Kith uses a **hybrid nesting strategy** to keep URLs readable without deep nesting.

### Sub-entity List + Create → Nested

Use the parent resource as a prefix when listing or creating sub-entities, because the parent
context is required.

```
GET    /api/contacts/:contact_id/notes       # list notes for a contact
POST   /api/contacts/:contact_id/notes       # create a note on a contact

GET    /api/contacts/:contact_id/addresses
POST   /api/contacts/:contact_id/addresses

GET    /api/contacts/:contact_id/tags
POST   /api/contacts/:contact_id/tags
```

### Sub-entity Show + Update + Delete → Flat

Once a sub-entity's `id` is known, access it directly without the parent prefix.

```
GET    /api/notes/:id
PUT    /api/notes/:id
DELETE /api/notes/:id

GET    /api/addresses/:id
PUT    /api/addresses/:id
DELETE /api/addresses/:id
```

**Rationale:** Avoids deeply nested URLs (`/contacts/:id/notes/:id/attachments/:id`) while
still conveying ownership clearly at creation time. The sub-entity `id` is globally unique, so
the parent segment adds no information for retrieval.

---

## 8. Request and Response Content-Type

| Direction | Content-Type |
|-----------|-------------|
| Request body | `application/json` |
| Success response | `application/json` |
| Error response | `application/problem+json` |

### Timestamps

All timestamp fields are **ISO 8601 in UTC**, with second precision:

```
"inserted_at": "2025-01-15T10:30:00Z"
"updated_at":  "2026-03-17T08:45:12Z"
```

- Do not use milliseconds unless a specific endpoint requires sub-second precision.
- Clients must treat timestamps as UTC; no timezone offsets are emitted.

---

## Quick Reference

```
# Paginated list with includes
GET /api/contacts?include=tags,notes&limit=25&cursor=<token>

# Create sub-entity (nested)
POST /api/contacts/01J9K2M.../notes

# Operate on known sub-entity (flat)
GET    /api/notes/01J9K5P...
PUT    /api/notes/01J9K5P...
DELETE /api/notes/01J9K5P...

# Auth
POST   /api/auth/token
DELETE /api/auth/token
```
