# CBRNE Intelligence Reading Room

An intelligence collection and reading environment. Not a news site.

Continuously collects CBRNE related reporting, government releases and
scientific literature, deduplicates and versions it, extracts entities
deterministically, and presents it in a reading interface built for long
sessions rather than for clicks.

---

## Build status, honestly

This repository is a spine, not a finished product. What is real and what is
not:

| Module | State |
| --- | --- |
| `db/schema.sql` | Written. 21 tables, 22 indexes, 1 view. Parser validated; CI applies it against real Postgres |
| `services/ingest/app/enrich/` | Written and tested. Canonicalisation, simhash, extractors, domain rules, pipeline decisions |
| `services/ingest/app/collectors/` | RSS, Atom and Europe PMC written and tested |
| `services/ingest/tests/` | 62 tests, no network, no database |
| `docs/ARCHITECTURE.md` | Complete. Architecture, ER diagram, API design, wireframes, pipelines, deployment |
| `docker/` | Compose and Dockerfile written, not yet run end to end |
| `app/main.py`, `app/cli.py`, persistence layer | **Not written.** Next module |
| `apps/web/` Next.js reader | **Not written.** Module after that |

Everything marked written has tests you can run right now. Nothing here is a
stub pretending to be an implementation.

## Quick start

```bash
git clone https://github.com/YOURNAME/cbrne-reading-room
cd cbrne-reading-room

# run the logic tests, no services needed
cd services/ingest && pip install pytest && python -m pytest tests/ -q

# bring up Postgres with the schema applied
cd ../.. && cp .env.example .env      # set POSTGRES_PASSWORD
docker compose -f docker/docker-compose.yml up -d db
```

## Two decisions that shape everything

### The capture layer and the interpretation layer are physically separate

`raw_documents` and `articles` hold what a source actually published.
`assessments` holds what a model thought about it, and every row there requires
a named producer, a prompt version, a timestamp and a statement of what the
model could not determine.

You can drop every row in `assessments` and lose nothing a source ever said.
That property is what makes the archive citable, and it is why
`ASSESSOR_ENABLED` defaults to `false` in the compose file. If the reading room
stops working with the assessor off, the layers have been coupled somewhere and
that is a bug, not a feature.

### Polling is tiered, and nothing polls every minute

GitHub caps scheduled workflows at five minutes and silently drops anything
faster: the YAML lints, the schedule shows in the UI, nothing fires. Even at
`*/5`, delays of 5 to 30 minutes are routine and runs are occasionally skipped
without trace.

| Tier | Cadence | Runtime | Content |
| --- | --- | --- | --- |
| 0 | 1 to 5 min | Cloudflare Worker cron or a VPS timer | Emergency alert feeds, short wire allowlist |
| 1 | 15 min | same | National press, agency newsrooms, GDELT |
| 2 | 1 to 6 h | either | Ministries, think tanks, NGOs |
| 3 | 12 to 24 h | GitHub Actions | OpenAlex, Europe PMC, Crossref, patents |

`poll_tier` on `source_feeds` carries this per feed. Conditional GET is
mandatory at tier 0: a one minute poll of a quiet feed must cost a 304 and no
body transfer, or the schedule is abusive to the publisher.

## Layout

```
db/schema.sql                    authoritative DDL
services/ingest/app/
  collectors/   base.py rss.py europepmc.py
  enrich/       canonical.py simhash.py extract.py domains.py pipeline.py
  tests/        62 tests, offline
docker/                          compose + Dockerfile
docs/
  ARCHITECTURE.md                the full design
  PUBLICATION_POLICY.md          what is indexed and what never is
.github/workflows/
  ci.yml                         tests + schema apply against real Postgres
  ingest-cold.yml                tier 3 only
```

## Engineering notes worth knowing

**CAS numbers carry a check digit.** `extract.py` validates it, which is what
stops `2024-01-15` and phone numbers being ingested as chemical identifiers.
The naive `\d{2,7}-\d{2}-\d` pattern is unusable without it.

**Every entity mention stores character offsets.** An entity table without
offsets is an unfalsifiable claim: you cannot check an extraction against the
text that produced it. The test suite asserts that every mention's offsets
still index the exact surface string.

**`ingest_runs` records failures, not just successes.** This is what turns "we
saw nothing" into a defensible statement rather than an ambiguous one, and it
is what the `collection_gaps` view reads.

**Simhash threshold is 3 bits, deliberately tight.** Loosening it collapses
genuinely independent reports of the same incident into one cluster, which
destroys the ability to see that six sources reported separately.

**Domain rules default to labelling on a single mention anywhere.** The costs
are asymmetric: a missed label means the article never appears in that domain
view at all, while a spurious label costs one item to skim. Precision comes
from how narrow the term lists are, not from raising the gate.

## Licence

AGPL-3.0-only for the code. Data licences are separate and per source; see
`docs/SOURCES.md` before enabling anything in a paid tier.

---

[CBRNE OSINT Reading Room](https://ss-shiri.github.io/kaf-cbrne/) ·
[ALEF OSINT](https://ss-shiri.github.io/ALEF-OSINT/) ·
[LinkedIn](https://www.linkedin.com/in/sajad-shiri/)
