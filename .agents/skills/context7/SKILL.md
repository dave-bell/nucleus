---
name: context7
description: Use when the user needs current documentation for a software library or framework, wants code examples for a specific API, needs to verify correct usage of a library function, or asks about a library API that may have changed since training data was cut off. Fetches live docs via the Context7 API.
---

# context7

Retrieve current documentation for software libraries via the Context7 API, instead of relying on potentially outdated training data.

For the full list of libraries this project treats as "always check live docs for" — including aliases and pre-built query optimization patterns — LOAD `references/library-registry.md`.

## Workflow

### Step 1: Search for the Library

```bash
curl -s "https://context7.com/api/v2/libs/search?libraryName=LIBRARY_NAME&query=TOPIC" | jq '.results[0]'
```

- `libraryName` (required): library name (e.g. "react", "nextjs", "fastapi")
- `query` (required): topic description for relevance ranking

Response fields: `id` (use in step 2), `title`, `description`, `totalSnippets`.

### Step 2: Fetch Documentation

```bash
curl -s "https://context7.com/api/v2/context?libraryId=LIBRARY_ID&query=TOPIC&type=txt"
```

- `libraryId` (required): from step 1
- `query` (required): specific topic
- `type` (optional): `json` (default) or `txt` (more readable)

## Examples

```bash
# React hooks
curl -s "https://context7.com/api/v2/libs/search?libraryName=react&query=hooks" | jq '.results[0].id'
curl -s "https://context7.com/api/v2/context?libraryId=/websites/react_dev_reference&query=useState&type=txt"

# Next.js routing
curl -s "https://context7.com/api/v2/libs/search?libraryName=nextjs&query=routing" | jq '.results[0].id'
curl -s "https://context7.com/api/v2/context?libraryId=/vercel/next.js&query=app+router&type=txt"
```

## Tips

- Use `type=txt` for more readable output.
- Use `jq` to filter/format JSON responses.
- Be specific with `query` to improve relevance ranking.
- If the first search result is wrong, check the rest of the `results` array.
- URL-encode spaces in query parameters (`+` or `%20`).
- No API key required for basic usage (rate-limited).

## Relationship to `external-lookup`

This skill is the low-level fetch mechanism. The `external-lookup` agent wraps it with caching (`.tmp/external-context/`), tech-stack-aware query enhancement, and mandatory persistence. Prefer invoking `external-lookup` for a full task; use this skill directly for a quick one-off lookup.
