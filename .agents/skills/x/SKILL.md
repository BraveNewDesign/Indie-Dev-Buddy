---
name: x
description: Use when building applications that interact with X (formerly
  Twitter) data and functionality. Reach for this skill when agents need to
  search posts, manage user data, handle authentication, work with streaming
  data, or integrate X features into applications. Common tasks include making
  API requests, configuring authentication, handling pagination and rate limits,
  and troubleshooting API errors.
metadata:
  mintlify-proj: x
  version: "1.0"
---

# X API Skill Reference

## Product Summary

The X API provides programmatic access to X's public conversation and user data through modern REST endpoints. Agents use it to search posts, retrieve user information, manage content, handle authentication, and stream real-time data. The platform offers two access tiers: **Pay-per-use** (credit-based, no commitments) and **Enterprise** (high-volume, custom limits).

**Key files and resources:**
- Developer Console: https://console.x.com (create apps, manage credentials)
- API base URL: `https://api.x.com/2/`
- Official SDKs: Python (`xdk`) and TypeScript (`@xdevplatform/xdk`)
- Comprehensive docs: https://docs.x.com/llms.txt

**Primary authentication methods:**
- OAuth 2.0 (recommended for new projects)
- OAuth 1.0a (user context)
- Bearer Token (app-only, public data)

---

## When to Use

Reach for this skill when:

- **Building integrations** — Embedding X content, posting updates, or syncing data
- **Searching and analyzing** — Finding posts by keyword, hashtag, or user; analyzing trends
- **Managing user data** — Retrieving profiles, followers, following lists, bookmarks
- **Streaming real-time data** — Monitoring posts matching rules or tracking specific accounts
- **Handling authentication** — Setting up OAuth flows, managing tokens, securing credentials
- **Troubleshooting API errors** — Debugging 401, 403, 429, or 400 responses
- **Optimizing requests** — Implementing pagination, respecting rate limits, using fields/expansions
- **Building bots or automation** — Creating scheduled posts, managing replies, automating workflows

---

## Quick Reference

### Essential Endpoints

| Task | Endpoint | Method | Auth |
|:-----|:---------|:-------|:-----|
| Look up user by username | `/2/users/by/username/{username}` | GET | Bearer Token |
| Get user by ID | `/2/users/{id}` | GET | Bearer Token |
| Search recent posts | `/2/tweets/search/recent` | GET | Bearer Token |
| Get post by ID | `/2/tweets/{id}` | GET | Bearer Token |
| Create post | `/2/tweets` | POST | OAuth 1.0a or 2.0 |
| Delete post | `/2/tweets/{id}` | DELETE | OAuth 1.0a or 2.0 |
| Get user's posts | `/2/users/{id}/tweets` | GET | Bearer Token |
| Follow user | `/2/users/{id}/following` | POST | OAuth 1.0a or 2.0 |
| Get followers | `/2/users/{id}/followers` | GET | Bearer Token |
| Filtered stream rules | `/2/tweets/search/stream/rules` | GET/POST | Bearer Token |
| Stream filtered posts | `/2/tweets/search/stream` | GET | Bearer Token |

### Common Query Parameters

| Parameter | Purpose | Example |
|:----------|:--------|:--------|
| `tweet.fields` | Request additional post fields | `created_at,public_metrics,author_id` |
| `user.fields` | Request additional user fields | `created_at,description,public_metrics` |
| `expansions` | Include related objects (author, media, etc.) | `author_id,attachments.media_keys` |
| `max_results` | Results per page (varies by endpoint) | `10` to `100` |
| `next_token` | Pagination token from previous response | (opaque string) |
| `query` | Search query (for search endpoints) | `from:xdevelopers` |
| `start_time` / `end_time` | Filter by date range (ISO 8601) | `2024-01-01T00:00:00Z` |

### Authentication Quick Setup

**Bearer Token (app-only, simplest):**
```bash
curl "https://api.x.com/2/users/by/username/xdevelopers" \
  -H "Authorization: Bearer YOUR_BEARER_TOKEN"
```

**OAuth 2.0 (user context, recommended):**
- Get Client ID and Secret from Developer Console
- Implement authorization code flow with PKCE
- Exchange code for access token
- Use token in `Authorization: Bearer` header

**OAuth 1.0a (legacy, still supported):**
- Get API Key, API Secret, Access Token, Access Token Secret
- Sign requests with OAuth 1.0a signature
- Use official SDKs to handle signing automatically

### SDK Quick Start

**Python:**
```python
from xdk import Client

client = Client(bearer_token="YOUR_BEARER_TOKEN")
response = client.users.get_by_username("xdevelopers")
print(response.data.username)
```

**TypeScript:**
```typescript
import { Client } from '@xdevplatform/xdk';

const client = new Client({ bearerToken: 'YOUR_BEARER_TOKEN' });
const user = await client.users.getByUsername('xdevelopers');
console.log(user.data?.username);
```

---

## Decision Guidance

### When to Use Bearer Token vs OAuth

| Scenario | Use Bearer Token | Use OAuth |
|:---------|:-----------------|:----------|
| Reading public data only | ✓ | — |
| Posting on behalf of user | — | ✓ |
| Accessing user's private data | — | ✓ |
| Bot automation | ✓ (if read-only) | ✓ (if posting) |
| Third-party app | — | ✓ |
| Server-side only | ✓ | ✓ |

### When to Use Fields vs Expansions

| Need | Use Fields | Use Expansions |
|:-----|:-----------|:---------------|
| More data on main object | ✓ | — |
| Related objects (author, media) | — | ✓ |
| Fields on related objects | ✓ (with expansions) | ✓ |
| Minimal response | Neither | — |

### Search vs Filtered Stream

| Use Case | Search | Filtered Stream |
|:---------|:-------|:-----------------|
| Historical data | ✓ | — |
| Real-time monitoring | — | ✓ |
| One-time query | ✓ | — |
| Continuous listening | — | ✓ |
| Complex queries | ✓ | ✓ |
| Latency < 5 seconds | — | ✓ |

---

## Workflow

### 1. Set Up Authentication

1. **Create a developer app** at https://console.x.com
2. **Choose auth method:**
   - For read-only public data: Copy Bearer Token
   - For posting/user actions: Set up OAuth 2.0 or 1.0a
3. **Store credentials securely:**
   - Use environment variables (never hardcode)
   - Add credential files to `.gitignore`
   - Rotate keys periodically
4. **Test authentication:**
   ```bash
   curl "https://api.x.com/2/users/by/username/xdevelopers" \
     -H "Authorization: Bearer $BEARER_TOKEN"
   ```

### 2. Make Your First Request

1. **Choose an endpoint** based on your task (user lookup, post search, etc.)
2. **Build the URL** with required path parameters
3. **Add query parameters:**
   - `tweet.fields` or `user.fields` for additional data
   - `expansions` for related objects
   - `max_results` for pagination
4. **Send the request** with proper `Authorization` header
5. **Parse the response:**
   - Check HTTP status code (2xx = success)
   - Extract data from `data` field
   - Handle `errors` array if present
   - Save `next_token` for pagination

### 3. Handle Pagination

1. **Check response** for `next_token` field
2. **If `next_token` exists:**
   - Make next request with same parameters
   - Add `next_token` query parameter
   - Repeat until `next_token` is absent
3. **Use SDKs** for automatic pagination:
   ```python
   for page in client.posts.search_recent(query="api", max_results=10):
       for post in page.data:
           print(post.text)
   ```

### 4. Respect Rate Limits

1. **Check response headers:**
   - `x-rate-limit-limit` — Max requests in window
   - `x-rate-limit-remaining` — Requests left
   - `x-rate-limit-reset` — Unix timestamp of reset
2. **If approaching limit:**
   - Cache responses
   - Spread requests across time window
   - Implement exponential backoff
3. **If you hit 429 (Too Many Requests):**
   - Wait until `x-rate-limit-reset` timestamp
   - Retry with exponential backoff (1s, 2s, 4s, etc.)

### 5. Troubleshoot Errors

1. **Check HTTP status code:**
   - 400 = Bad request (invalid parameters)
   - 401 = Unauthorized (auth issue)
   - 403 = Forbidden (no access)
   - 404 = Not found (resource deleted)
   - 429 = Rate limited
   - 5xx = Server error (retry later)
2. **Read error response** for `detail` and `type` fields
3. **Verify:**
   - Credentials are correct and not regenerated
   - App has access to endpoint
   - Query syntax is valid
   - Required fields are present
4. **Check status page** at https://developer.x.com/status for outages

---

## Common Gotchas

- **Hardcoded credentials** — Never commit API keys to git. Use environment variables and `.gitignore`.
- **Minimal fields by default** — Posts return only `id`, `text`, and `edit_history_tweet_ids`. Always add `tweet.fields` for additional data.
- **Expansions without fields** — Using `expansions=author_id` returns the author ID but not author details. Add `user.fields` to get author data.
- **Pagination token expiry** — `next_token` values expire after a period. Don't cache them for later use.
- **Protected accounts** — Posts from protected accounts are only visible with proper authorization.
- **Deleted posts return 404** — Don't retry; the post is gone.
- **Rate limits reset per endpoint** — Each endpoint has its own 15-minute window. Hitting one limit doesn't affect others.
- **OAuth 2.0 scopes** — Requesting new scopes requires users to re-authorize. Request only what you need.
- **Callback URL must match exactly** — Including protocol, domain, path, and trailing slashes. Use `http://127.0.0.1` for local dev, not `localhost`.
- **Bearer Token is app-only** — Can't access private user data or post on behalf of users. Use OAuth for those.
- **Streaming disconnections are normal** — Implement automatic reconnect with exponential backoff.
- **Search queries have syntax** — Use operators like `from:`, `to:`, `lang:`, `has:links`. Invalid syntax returns 400.

---

## Verification Checklist

Before submitting work with the X API:

- [ ] **Authentication works** — Test with a simple endpoint (user lookup)
- [ ] **Credentials are secure** — Stored in environment variables, not in code
- [ ] **Fields are requested** — Added `tweet.fields` or `user.fields` for needed data
- [ ] **Expansions are paired with fields** — If using `expansions`, also added corresponding `*.fields`
- [ ] **Pagination is handled** — Code checks for `next_token` and loops until absent
- [ ] **Rate limits are respected** — Implemented backoff for 429 responses
- [ ] **Errors are handled** — Code checks HTTP status and parses error responses
- [ ] **Response parsing is correct** — Data is in `data` field, not at root level
- [ ] **Query syntax is valid** — Tested search queries with operators
- [ ] **Callback URLs match** — For OAuth flows, URLs match exactly in Developer Console
- [ ] **Scopes are minimal** — Only requested OAuth permissions actually needed
- [ ] **Tests pass** — Verified with real API calls or mock server

---

## Resources

**Comprehensive navigation:** https://docs.x.com/llms.txt

**Critical documentation pages:**
1. [Make Your First Request](https://docs.x.com/make-your-first-request) — Step-by-step guide to your first API call
2. [Authentication Overview](https://docs.x.com/fundamentals/authentication/overview) — All auth methods explained
3. [Response Codes & Errors](https://docs.x.com/x-api/fundamentals/response-codes-and-errors) — Debugging HTTP errors and status codes
4. [Fields & Expansions](https://docs.x.com/x-api/fundamentals/fields) — How to request additional data
5. [Rate Limits](https://docs.x.com/fundamentals/rate-limits) — Understanding and respecting limits
6. [Developer Apps](https://docs.x.com/fundamentals/developer-apps) — Creating and managing credentials
7. [Tools & Libraries](https://docs.x.com/tools-and-libraries) — Official SDKs and community libraries

---

> For additional documentation and navigation, see: https://docs.x.com/llms.txt