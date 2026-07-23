-- ============================================================================
-- CBRNE Intelligence Reading Room
-- PostgreSQL 15+ schema
--
-- Architectural rule that shapes this entire file:
--   The capture layer and the interpretation layer are physically separate.
--   raw_documents and articles hold what a source actually published.
--   assessments holds what a model thought about it, always attributed to a
--   named model and prompt version, always timestamped, always deletable
--   without touching the archive.
--
--   Consequence: you can drop every row in assessments and lose nothing that
--   a source ever said. That property is what makes the archive citable.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS citext;

-- ---------------------------------------------------------------- enums

CREATE TYPE threat_domain AS ENUM (
  'chemical','biological','radiological','nuclear','explosive',
  'cyber','health','industry'
);

CREATE TYPE source_kind AS ENUM (
  'government','military','defence_ministry','interior_ministry',
  'health_ministry','environment_agency','customs','police','fire',
  'university','research_institute','think_tank','intergovernmental',
  'newspaper_national','newspaper_regional','newspaper_local',
  'company_newsroom','press_release','journal','preprint_server',
  'conference','podcast','other'
);

CREATE TYPE ingest_method AS ENUM (
  'rss','atom','sitemap','json_api','xml_api','scrape','github_release','manual'
);

CREATE TYPE entity_kind AS ENUM (
  'organization','country','city','facility','laboratory',
  'chemical','pathogen','virus','bacterium','toxin','isotope','explosive',
  'person','company','institution','funding_agency','project',
  'hs_code','un_number','cas_number','hazard_class'
);

-- Deliberately NOT an enum of "confidence levels". Assessment kinds are
-- open ended and each carries its own numeric or categorical payload.
CREATE TYPE assessment_kind AS ENUM (
  'summary_executive','summary_one_line','keywords','topic_cluster',
  'threat_relevance','source_credibility','bias_estimate',
  'geolocation','language_detect','translation','event_extract','priority'
);

CREATE TYPE run_status AS ENUM ('ok','partial','failed','skipped');

-- ---------------------------------------------------------------- reference

CREATE TABLE countries (
  iso2         CHAR(2) PRIMARY KEY,
  iso3         CHAR(3) UNIQUE NOT NULL,
  name         TEXT NOT NULL,
  region       TEXT,
  subregion    TEXT,
  centroid_lat DOUBLE PRECISION,
  centroid_lon DOUBLE PRECISION
);

CREATE TABLE tags (
  id         SERIAL PRIMARY KEY,
  slug       TEXT UNIQUE NOT NULL,
  label      TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- sources

CREATE TABLE sources (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  slug          TEXT UNIQUE NOT NULL,
  name          TEXT NOT NULL,
  kind          source_kind NOT NULL,
  homepage      TEXT,
  country_iso2  CHAR(2) REFERENCES countries(iso2),
  language      TEXT,
  -- Descriptive provenance only. This is NOT a credibility ranking and must
  -- never be rendered as one. It records what kind of body publishes here.
  state_affiliated  BOOLEAN NOT NULL DEFAULT FALSE,
  peer_reviewed     BOOLEAN NOT NULL DEFAULT FALSE,
  notes         TEXT,
  active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE source_feeds (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  source_id      UUID NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  url            TEXT NOT NULL,
  method         ingest_method NOT NULL,
  -- Scheduling tier. See docs/ARCHITECTURE.md. Literature endpoints must not
  -- sit in the hot tier: papers do not change minute to minute and polling
  -- them that fast is abusive to the upstream and returns nothing new.
  poll_tier      SMALLINT NOT NULL DEFAULT 2 CHECK (poll_tier BETWEEN 0 AND 3),
  selector       JSONB,          -- scrape selectors / API params
  etag           TEXT,           -- conditional GET
  last_modified  TEXT,
  last_polled_at TIMESTAMPTZ,
  last_ok_at     TIMESTAMPTZ,
  consecutive_failures INT NOT NULL DEFAULT 0,
  active         BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (source_id, url)
);

CREATE INDEX ON source_feeds (poll_tier, active, last_polled_at);

-- ---------------------------------------------------------------- capture

-- Immutable. One row per successful fetch of one document. Never updated,
-- never deleted by application code. This is the evidentiary layer.
CREATE TABLE raw_documents (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  feed_id       UUID REFERENCES source_feeds(id) ON DELETE SET NULL,
  url           TEXT NOT NULL,
  url_sha256    CHAR(64) NOT NULL,
  body_sha256   CHAR(64) NOT NULL,
  content_type  TEXT,
  http_status   INT,
  body          BYTEA,          -- compressed payload, or NULL if offloaded
  storage_key   TEXT,           -- object storage key when body is offloaded
  fetched_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ON raw_documents (url_sha256, fetched_at DESC);
CREATE INDEX ON raw_documents (body_sha256);
CREATE INDEX ON raw_documents (fetched_at DESC);

-- ---------------------------------------------------------------- articles

CREATE TABLE clusters (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  centroid     JSONB,           -- embedding centroid or shingle signature
  label        TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  member_count  INT NOT NULL DEFAULT 0
);

CREATE TABLE articles (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  source_id      UUID NOT NULL REFERENCES sources(id),
  cluster_id     UUID REFERENCES clusters(id) ON DELETE SET NULL,

  canonical_url  TEXT NOT NULL,
  url_sha256     CHAR(64) NOT NULL UNIQUE,

  title          TEXT NOT NULL,
  byline         TEXT,
  language       TEXT,
  published_at   TIMESTAMPTZ,
  -- Set once by the ingest run that first observed this article. Never
  -- rewritten. The gap between first_seen_at and any later official
  -- confirmation is the detection latency dataset.
  first_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_changed_at TIMESTAMPTZ,

  -- Extracted reader text. Stored for search and reading, never redistributed
  -- as a feed. See docs/ARCHITECTURE.md on the press publishers' right.
  body_text      TEXT,
  word_count     INT,
  reading_minutes SMALLINT,

  current_version INT NOT NULL DEFAULT 1,
  retracted       BOOLEAN NOT NULL DEFAULT FALSE,
  retraction_note TEXT,

  search_tsv     TSVECTOR
);

CREATE INDEX ON articles (published_at DESC NULLS LAST);
CREATE INDEX ON articles (first_seen_at DESC);
CREATE INDEX ON articles (source_id, published_at DESC);
CREATE INDEX ON articles (cluster_id);
CREATE INDEX articles_tsv_idx  ON articles USING GIN (search_tsv);
CREATE INDEX articles_trgm_idx ON articles USING GIN (title gin_trgm_ops);

CREATE FUNCTION articles_tsv_update() RETURNS trigger AS $$
BEGIN
  NEW.search_tsv :=
      setweight(to_tsvector('simple', coalesce(NEW.title,'')), 'A')
   || setweight(to_tsvector('simple', coalesce(NEW.body_text,'')), 'D');
  RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER articles_tsv_trg
  BEFORE INSERT OR UPDATE OF title, body_text ON articles
  FOR EACH ROW EXECUTE FUNCTION articles_tsv_update();

-- Every observed state of an article. An edit upstream appends here rather
-- than overwriting. Satisfies "detect updates, archive every version".
CREATE TABLE article_versions (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  article_id     UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  version        INT NOT NULL,
  raw_document_id UUID REFERENCES raw_documents(id),
  title          TEXT NOT NULL,
  body_text      TEXT,
  body_sha256    CHAR(64) NOT NULL,
  diff_summary   JSONB,          -- {added:[], removed:[], fields:[]}
  observed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (article_id, version)
);

CREATE INDEX ON article_versions (article_id, version DESC);

-- ---------------------------------------------------------------- taxonomy

CREATE TABLE article_domains (
  article_id UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  domain     threat_domain NOT NULL,
  -- how this label was applied: 'rule' (deterministic keyword/source rule)
  -- or an assessment id. Rule-derived labels survive deleting the AI layer.
  method     TEXT NOT NULL DEFAULT 'rule',
  PRIMARY KEY (article_id, domain)
);

CREATE INDEX ON article_domains (domain, article_id);

CREATE TABLE article_countries (
  article_id   UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  country_iso2 CHAR(2) NOT NULL REFERENCES countries(iso2),
  role         TEXT,            -- 'dateline' | 'mentioned' | 'source_country'
  PRIMARY KEY (article_id, country_iso2, role)
);

CREATE INDEX ON article_countries (country_iso2, article_id);

CREATE TABLE article_tags (
  article_id UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  tag_id     INT  NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (article_id, tag_id)
);

-- ---------------------------------------------------------------- entities

CREATE TABLE entities (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  kind        entity_kind NOT NULL,
  canonical   TEXT NOT NULL,
  -- external identifiers, e.g. {"cas":"7647-01-0","pubchem":313,
  -- "wikidata":"Q2901","ror":"01xyz","unnumber":"1789"}
  identifiers JSONB NOT NULL DEFAULT '{}'::JSONB,
  country_iso2 CHAR(2) REFERENCES countries(iso2),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (kind, canonical)
);

CREATE INDEX ON entities USING GIN (identifiers);
CREATE INDEX ON entities USING GIN (canonical gin_trgm_ops);

CREATE TABLE entity_aliases (
  entity_id UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  alias     TEXT NOT NULL,
  lang      TEXT,
  PRIMARY KEY (entity_id, alias)
);

CREATE INDEX ON entity_aliases USING GIN (alias gin_trgm_ops);

-- Mention level, not document level. Character offsets make every extraction
-- traceable back to the exact span of source text that produced it. Without
-- offsets an entity table is an unfalsifiable claim.
CREATE TABLE article_entities (
  article_id UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  entity_id  UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  span_start INT,
  span_end   INT,
  surface    TEXT,
  extractor  TEXT NOT NULL,     -- 'regex:cas' | 'gazetteer:iaea' | 'ner:model@v'
  confidence REAL CHECK (confidence BETWEEN 0 AND 1),
  PRIMARY KEY (article_id, entity_id, span_start)
);

CREATE INDEX ON article_entities (entity_id, article_id);

-- ---------------------------------------------------------------- assessments

-- Everything a model asserts lives here and nowhere else. Note the mandatory
-- provenance columns: an assessment without a named producer cannot be
-- inserted. The UI is required to render producer and produced_at beside any
-- score it displays.
CREATE TABLE assessments (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  article_id  UUID REFERENCES articles(id) ON DELETE CASCADE,
  cluster_id  UUID REFERENCES clusters(id) ON DELETE CASCADE,
  kind        assessment_kind NOT NULL,

  producer     TEXT NOT NULL,   -- model identifier, e.g. 'claude-sonnet-4-6'
  prompt_version TEXT NOT NULL, -- git sha of the prompt template
  produced_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  value_text  TEXT,
  value_num   REAL,
  value_json  JSONB,
  -- Free text stating what the model could not determine. Populated on every
  -- assessment. An empty gaps field is treated as a bug, not as certainty.
  gaps        TEXT,

  superseded_by UUID REFERENCES assessments(id),

  CHECK (article_id IS NOT NULL OR cluster_id IS NOT NULL)
);

CREATE INDEX ON assessments (article_id, kind, produced_at DESC);
CREATE INDEX ON assessments (kind, produced_at DESC);
CREATE INDEX ON assessments (producer, prompt_version);

-- ---------------------------------------------------------------- users

CREATE TABLE users (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email      CITEXT UNIQUE,
  display_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE collections (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, name)
);

CREATE TABLE collection_items (
  collection_id UUID NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  article_id    UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
  note          TEXT,
  added_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (collection_id, article_id)
);

CREATE TABLE bookmarks (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL CHECK (target_type IN
                ('article','source','country','entity','search')),
  target_id   TEXT NOT NULL,
  note        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, target_type, target_id)
);

CREATE TABLE saved_searches (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  query      JSONB NOT NULL,   -- parsed boolean AST, not a raw string
  alerting   BOOLEAN NOT NULL DEFAULT FALSE,
  last_run_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, name)
);

-- ---------------------------------------------------------------- observability

-- Every poll of every feed, successful or not. This table is what turns
-- "we saw nothing" into a defensible statement: you can distinguish a quiet
-- source from a broken one. Collection gap reporting reads from here.
CREATE TABLE ingest_runs (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  feed_id       UUID REFERENCES source_feeds(id) ON DELETE CASCADE,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at   TIMESTAMPTZ,
  status        run_status NOT NULL,
  http_status   INT,
  items_seen    INT NOT NULL DEFAULT 0,
  items_new     INT NOT NULL DEFAULT 0,
  error         TEXT
);

CREATE INDEX ON ingest_runs (feed_id, started_at DESC);
CREATE INDEX ON ingest_runs (status, started_at DESC);

-- Rolling view of which sources have gone quiet. Drives the Collection Gaps
-- panel. A source that has not returned an item in 72h is surfaced, which is
-- the difference between an absence of evidence and evidence of absence.
CREATE VIEW collection_gaps AS
SELECT f.id            AS feed_id,
       s.name          AS source_name,
       s.kind          AS source_kind,
       f.url,
       f.poll_tier,
       f.last_ok_at,
       f.consecutive_failures,
       now() - f.last_ok_at AS silent_for
FROM source_feeds f
JOIN sources s ON s.id = f.source_id
WHERE f.active
  AND (f.last_ok_at IS NULL OR f.last_ok_at < now() - INTERVAL '72 hours');
