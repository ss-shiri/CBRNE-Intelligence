# CBRNE Intelligence Reading Room
## Architecture and Implementation Strategy

This document defines the technical architecture for an evidence-centric CBRNE
(Chemical, Biological, Radiological, Nuclear, Explosive) intelligence platform
built for large-scale open-source collection, provenance preservation, entity
extraction, and optional AI-assisted analytical workflows.

The system rests on three core principles:

1. **Evidence preservation** — Original source material and collection
   metadata are stored separately from derived analytical products. Nothing
   downstream is allowed to overwrite or obscure the source record.
2. **Reproducible intelligence workflows** — Every transformation,
   enrichment step, and analytical output carries provenance, versioning,
   and traceability back to its inputs.
3. **Modular intelligence processing** — Collection, enrichment, and
   analytical assessment are independent components. Each layer can run,
   fail, and be validated on its own without taking down the others.

---

## Architecture Constraints

### 1. Collection Frequency and Scheduling

GitHub Actions scheduled workflows are not suitable for high-frequency
monitoring — they run best-effort, with queueing delays and no guaranteed
cadence under load. High-frequency collection needs dedicated scheduling
infrastructure instead:

| Tier | Frequency | Recommended Runtime | Purpose |
|---|---|---|---|
| Tier 0 | 1–5 min | Cloudflare Workers / VPS scheduler | Critical alerts, priority feeds |
| Tier 1 | 15 min | Persistent worker service | Agency news, media monitoring |
| Tier 2 | 1–6 hr | Worker service or GitHub Actions | Institutional reporting |
| Tier 3 | 12–24 hr | GitHub Actions | Academic databases, publications, patents |

The GitHub repository remains the source of truth for software; all
operational/runtime data lives in PostgreSQL, not in the repo.

---

## Evidence and Analysis Separation

Collected evidence and analytical interpretation are kept in separate table
families:

- **Evidence layer:** `raw_documents`, `articles`, `article_versions`
- **Analysis layer:** `assessments`

AI-generated products must never modify original evidence records. Every
analytical output must carry:

- producing model/system identifier
- prompt or processing pipeline version
- timestamp
- stated uncertainty or known information gaps

This keeps analytical output from ever being mistaken for source evidence —
a hard requirement for anything presented as intelligence.

---

## Why the Site Is Currently Empty

The frontend renders correctly (navigation, categories, workspace panel all
load), but there's no content because nothing has populated the database
yet. `schema.sql` only defines table structure — it does not seed data. The
site will stay empty until the pipeline below actually runs end-to-end:
schema deployed → sources registered → collectors executed → articles
land in `raw_documents`/`articles` → the reader/search layer has something
to query. Worth confirming, in order: (1) has `schema.sql` been applied to
a live Postgres instance, (2) does a source registry have at least one feed
in it, (3) has any collector run and written rows, (4) does the frontend's
API endpoint actually point at that database. Any break in that chain
produces exactly this "empty template" symptom.

---

## Development Scope

The full platform's target capabilities:

- multi-source ingestion
- CBRNE entity extraction
- semantic search
- country and domain intelligence views
- provenance tracking
- optional AI-assisted analysis

Build this as validated vertical slices, not as one big-bang implementation.
The first operational milestone, in order:

1. Database deployment
2. Source registry
3. RSS and scientific-database collectors
4. Deduplication and version tracking
5. Search API
6. Reader interface
7. Collection monitoring dashboard

Each step should be independently testable before the next begins — this
is what turns "empty template" into a working pipeline.
