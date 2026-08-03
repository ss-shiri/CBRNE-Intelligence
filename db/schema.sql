-- =============================================================================
-- CBRNE Intelligence Reading Room — Database Schema
-- =============================================================================
-- 21 tables, 22 indexes (excl. automatic PK/UNIQUE indexes), 1 view.
--
-- Design principles (see docs/ARCHITECTURE.md):
--   1. Evidence preservation   — raw_documents/articles/article_versions are
--                                 never mutated by downstream analysis.
--   2. Reproducible workflows  — every derived row carries provenance
--                                 (producing pipeline/model, version, timestamp).
--   3. Modular processing      — collection, enrichment, and assessment layers
--                                 are independent table families with FK-only
--                                 coupling, so each can be validated in isolation.
--
-- Target: PostgreSQL 14+
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fuzzy / alias matching
CREATE EXTENSION IF NOT EXISTS unaccent;   -- normalization for entity matching

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------

-- Matches the frontend's fixed threat-category taxonomy (World > Threat categories)
CREATE TYPE threat_category_code AS ENUM (
    'chemical', 'biological', 'radiological', 'nuclear',
    'explosive', 'cyber', 'health', 'industry'
);

-- Collection scheduling tiers (see ARCHITECTURE.md §Architecture Constraints)
CREATE TYPE source_tier AS ENUM ('tier_0', 'tier_1', 'tier_2', 'tier_3');

CREATE TYPE collector_type AS ENUM ('rss', 'atom', 'europe_pmc', 'api', 'manual');

CREATE TYPE run_status AS ENUM ('running', 'success', 'partial', 'failed');

-- Used on assessments only — never on evidence-layer tables.
CREATE TYPE confidence_level AS ENUM ('low', 'moderate', 'high');

CREATE TYPE entity_kind AS ENUM (
    'agent', 'pathogen', 'chemical_compound', 'isotope', 'material',
    'organization', 'person', 'facility', 'weapon_system', 'other'
);

-- -----------------------------------------------------------------------------
-- 1. users  — workspace owners (bookmarks, saved views); auth is out of scope
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT UNIQUE NOT NULL,
    display_name  TEXT,
    role          TEXT NOT NULL DEFAULT 'analyst',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 2. sources  — the source registry (milestone #2)
-- -----------------------------------------------------------------------------
CREATE TABLE sources (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    homepage_url    TEXT,
    feed_url        TEXT,
    collector_type  collector_type NOT NULL,
    tier            source_tier NOT NULL DEFAULT 'tier_3',
    country_code    TEXT,                       -- ISO 3166-1 alpha-2, nullable (e.g. multinational orgs)
    is_active       BOOLEAN NOT NULL DEFAULT true,
    trust_weight    NUMERIC(3,2) NOT NULL DEFAULT 0.50 CHECK (trust_weight BETWEEN 0 AND 1),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (feed_url)
);

-- -----------------------------------------------------------------------------
-- 3. raw_documents  — immutable fetch snapshots (evidence layer)
-- -----------------------------------------------------------------------------
CREATE TABLE raw_documents (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id        UUID NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
    collection_run_id UUID,                     -- FK added after collection_runs exists
    fetched_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    request_url      TEXT NOT NULL,
    http_status      INTEGER,
    content_type     TEXT,
    content_hash     TEXT NOT NULL,              -- sha256 of raw payload, for exact-dup detection
    raw_payload      TEXT NOT NULL,               -- original bytes as fetched (HTML/XML/JSON), unmodified
    raw_headers      JSONB,
    CONSTRAINT raw_documents_immutable_note CHECK (raw_payload IS NOT NULL)
);
COMMENT ON TABLE raw_documents IS
    'Immutable evidence snapshot. Never updated after insert; corrections happen via a new row, not UPDATE.';

-- -----------------------------------------------------------------------------
-- 4. dedup_clusters  — simhash-based near-duplicate grouping
-- -----------------------------------------------------------------------------
CREATE TABLE dedup_clusters (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    simhash        BIGINT NOT NULL,
    representative_article_id UUID,             -- FK added after articles exists
    member_count   INTEGER NOT NULL DEFAULT 1,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 5. articles  — canonical, current-state article record (evidence layer)
-- -----------------------------------------------------------------------------
CREATE TABLE articles (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id         UUID NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
    raw_document_id   UUID NOT NULL REFERENCES raw_documents(id) ON DELETE RESTRICT,
    dedup_cluster_id  UUID REFERENCES dedup_clusters(id) ON DELETE SET NULL,
    canonical_url     TEXT NOT NULL,
    title             TEXT NOT NULL,
    summary           TEXT,                       -- extractor-generated, not AI analysis
    body_text         TEXT,
    language          TEXT,                        -- ISO 639-1
    published_at      TIMESTAMPTZ,
    collected_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    simhash           BIGINT,
    content_hash      TEXT NOT NULL,
    pipeline_decision TEXT,                        -- e.g. 'accepted', 'filtered_offtopic', 'duplicate'
    search_vector     TSVECTOR,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (canonical_url)
);

ALTER TABLE raw_documents
    ADD CONSTRAINT fk_raw_documents_article
    FOREIGN KEY (collection_run_id) REFERENCES sources(id) DEFERRABLE INITIALLY DEFERRED;
-- Note: corrected below once collection_runs is defined (see ALTER near table 18).

ALTER TABLE dedup_clusters
    ADD CONSTRAINT fk_dedup_representative_article
    FOREIGN KEY (representative_article_id) REFERENCES articles(id) ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- 6. article_versions  — full version history of a canonical article
-- -----------------------------------------------------------------------------
CREATE TABLE article_versions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id     UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    title          TEXT NOT NULL,
    summary        TEXT,
    body_text      TEXT,
    diff_from_prev JSONB,                          -- structured diff vs version_number - 1
    raw_document_id UUID NOT NULL REFERENCES raw_documents(id) ON DELETE RESTRICT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (article_id, version_number)
);

-- -----------------------------------------------------------------------------
-- 7. categories  — the 8 fixed threat categories shown in the sidebar
-- -----------------------------------------------------------------------------
CREATE TABLE categories (
    id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code   threat_category_code NOT NULL UNIQUE,
    label  TEXT NOT NULL
);

-- -----------------------------------------------------------------------------
-- 8. article_categories  — M:N article <-> category tagging
-- -----------------------------------------------------------------------------
CREATE TABLE article_categories (
    article_id   UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    category_id  UUID NOT NULL REFERENCES categories(id) ON DELETE RESTRICT,
    confidence   NUMERIC(3,2) CHECK (confidence BETWEEN 0 AND 1),  -- classifier confidence, not analytic confidence
    assigned_by  TEXT NOT NULL DEFAULT 'pipeline',                 -- 'pipeline' | 'manual:<user_id>'
    PRIMARY KEY (article_id, category_id)
);

-- -----------------------------------------------------------------------------
-- 9. countries  — country registry (World / Countries nav)
-- -----------------------------------------------------------------------------
CREATE TABLE countries (
    code   TEXT PRIMARY KEY,      -- ISO 3166-1 alpha-2
    name   TEXT NOT NULL,
    region TEXT
);

-- -----------------------------------------------------------------------------
-- 10. article_countries  — M:N geotagging of articles
-- -----------------------------------------------------------------------------
CREATE TABLE article_countries (
    article_id    UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    country_code  TEXT NOT NULL REFERENCES countries(code) ON DELETE RESTRICT,
    relevance     TEXT NOT NULL DEFAULT 'mentioned',   -- 'mentioned' | 'primary_actor' | 'location'
    PRIMARY KEY (article_id, country_code, relevance)
);

-- -----------------------------------------------------------------------------
-- 11. organizations  — orgs referenced across articles (agencies, NGOs, firms)
-- -----------------------------------------------------------------------------
CREATE TABLE organizations (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL,
    org_type     TEXT,                 -- 'government' | 'ngo' | 'academic' | 'commercial' | 'multilateral'
    country_code TEXT REFERENCES countries(code) ON DELETE SET NULL,
    homepage_url TEXT,
    UNIQUE (name, org_type)
);

-- -----------------------------------------------------------------------------
-- 12. article_organizations  — M:N
-- -----------------------------------------------------------------------------
CREATE TABLE article_organizations (
    article_id      UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    role            TEXT,             -- 'source' | 'subject' | 'responder' | 'cited'
    PRIMARY KEY (article_id, organization_id, role)
);

-- -----------------------------------------------------------------------------
-- 13. entities  — canonical CBRNE-relevant entity dictionary
-- -----------------------------------------------------------------------------
CREATE TABLE entities (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind         entity_kind NOT NULL,
    canonical_name TEXT NOT NULL,
    category_id  UUID REFERENCES categories(id) ON DELETE SET NULL,  -- primary associated threat category
    external_ref JSONB,             -- e.g. {"cas_number": "...", "unii": "...", "isotope": "..."}
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (kind, canonical_name)
);

-- -----------------------------------------------------------------------------
-- 14. entity_aliases  — alternate names/spellings for fuzzy matching
-- -----------------------------------------------------------------------------
CREATE TABLE entity_aliases (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id  UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    alias      TEXT NOT NULL,
    language   TEXT,
    UNIQUE (entity_id, alias)
);

-- -----------------------------------------------------------------------------
-- 15. article_entities  — extracted entity mentions (enrichment output)
-- -----------------------------------------------------------------------------
CREATE TABLE article_entities (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id     UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    entity_id      UUID NOT NULL REFERENCES entities(id) ON DELETE RESTRICT,
    mention_text   TEXT NOT NULL,
    span_start     INTEGER,
    span_end       INTEGER,
    extractor_name TEXT NOT NULL,        -- provenance: which extractor produced this
    extractor_version TEXT NOT NULL,
    confidence     NUMERIC(3,2) CHECK (confidence BETWEEN 0 AND 1),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 16. assessments  — analytical products (analysis layer; never edits evidence)
-- -----------------------------------------------------------------------------
CREATE TABLE assessments (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id    UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    summary       TEXT NOT NULL,
    confidence    confidence_level NOT NULL,
    information_gaps TEXT,
    produced_by   TEXT NOT NULL,        -- model/system identifier, e.g. 'claude-sonnet-5'
    prompt_version TEXT NOT NULL,
    created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,  -- null if fully automated
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE assessments IS
    'Analytical layer. Read-only relative to evidence tables — an assessment references an article, it never mutates one.';

-- -----------------------------------------------------------------------------
-- 17. assessment_versions  — revision history for an assessment
-- -----------------------------------------------------------------------------
CREATE TABLE assessment_versions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id  UUID NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    summary        TEXT NOT NULL,
    confidence     confidence_level NOT NULL,
    produced_by    TEXT NOT NULL,
    prompt_version TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (assessment_id, version_number)
);

-- -----------------------------------------------------------------------------
-- 18. collection_runs  — one row per collector execution (monitoring dashboard)
-- -----------------------------------------------------------------------------
CREATE TABLE collection_runs (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id      UUID NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    collector_type collector_type NOT NULL,
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at    TIMESTAMPTZ,
    status         run_status NOT NULL DEFAULT 'running',
    items_seen     INTEGER NOT NULL DEFAULT 0,
    items_new      INTEGER NOT NULL DEFAULT 0,
    items_duplicate INTEGER NOT NULL DEFAULT 0,
    runner_version TEXT NOT NULL          -- git sha / package version of the collector
);

-- fix raw_documents.collection_run_id to point at the correct table
ALTER TABLE raw_documents DROP CONSTRAINT fk_raw_documents_article;
ALTER TABLE raw_documents
    ADD CONSTRAINT fk_raw_documents_collection_run
    FOREIGN KEY (collection_run_id) REFERENCES collection_runs(id) ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- 19. collection_errors  — structured error log per run
-- -----------------------------------------------------------------------------
CREATE TABLE collection_errors (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_run_id UUID NOT NULL REFERENCES collection_runs(id) ON DELETE CASCADE,
    occurred_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    error_type        TEXT NOT NULL,      -- 'fetch_timeout' | 'parse_error' | 'auth_error' | ...
    message           TEXT NOT NULL,
    context           JSONB
);

-- -----------------------------------------------------------------------------
-- 20. bookmarks  — per-user saved articles (Workspace / Bookmarks)
-- -----------------------------------------------------------------------------
CREATE TABLE bookmarks (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    article_id  UUID NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    note        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, article_id)
);

-- -----------------------------------------------------------------------------
-- 21. collection_gaps  — declared/inferred coverage gaps (Workspace / Collection gaps)
-- -----------------------------------------------------------------------------
CREATE TABLE collection_gaps (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id  UUID REFERENCES categories(id) ON DELETE SET NULL,
    country_code TEXT REFERENCES countries(code) ON DELETE SET NULL,
    description  TEXT NOT NULL,
    detected_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at  TIMESTAMPTZ
);

-- =============================================================================
-- Indexes (22 total, beyond automatic PK/UNIQUE indexes)
-- =============================================================================

-- articles
CREATE INDEX idx_articles_source_id        ON articles (source_id);
CREATE INDEX idx_articles_published_at     ON articles (published_at DESC);
CREATE INDEX idx_articles_dedup_cluster_id ON articles (dedup_cluster_id);
CREATE INDEX idx_articles_content_hash     ON articles (content_hash);
CREATE INDEX idx_articles_search_vector    ON articles USING GIN (search_vector);

-- raw_documents
CREATE INDEX idx_raw_documents_source_id    ON raw_documents (source_id);
CREATE INDEX idx_raw_documents_fetched_at   ON raw_documents (fetched_at DESC);
CREATE INDEX idx_raw_documents_content_hash ON raw_documents (content_hash);

-- article_versions
CREATE INDEX idx_article_versions_article_id ON article_versions (article_id);

-- article_categories
CREATE INDEX idx_article_categories_category_id ON article_categories (category_id);

-- article_countries
CREATE INDEX idx_article_countries_country_code ON article_countries (country_code);

-- article_organizations
CREATE INDEX idx_article_organizations_org_id ON article_organizations (organization_id);

-- entities / aliases / mentions
CREATE INDEX idx_entity_aliases_entity_id     ON entity_aliases (entity_id);
CREATE INDEX idx_entity_aliases_alias_trgm    ON entity_aliases USING GIN (alias gin_trgm_ops);
CREATE INDEX idx_article_entities_article_id  ON article_entities (article_id);
CREATE INDEX idx_article_entities_entity_id   ON article_entities (entity_id);

-- assessments
CREATE INDEX idx_assessments_article_id            ON assessments (article_id);
CREATE INDEX idx_assessment_versions_assessment_id ON assessment_versions (assessment_id);

-- collection monitoring
CREATE INDEX idx_collection_runs_source_id       ON collection_runs (source_id);
CREATE INDEX idx_collection_errors_run_id          ON collection_errors (collection_run_id);

-- bookmarks / gaps
CREATE INDEX idx_bookmarks_article_id       ON bookmarks (article_id);
CREATE INDEX idx_collection_gaps_category_id ON collection_gaps (category_id);

-- =============================================================================
-- View (1 total)
-- =============================================================================

-- Feeds the Collection Monitoring Dashboard (roadmap milestone #7):
-- per-source health over the most recent run plus a 7-day rolling error count.
CREATE VIEW v_source_collection_health AS
SELECT
    s.id                                AS source_id,
    s.name                              AS source_name,
    s.tier,
    s.is_active,
    latest.id                           AS latest_run_id,
    latest.status                       AS latest_status,
    latest.started_at                   AS latest_run_started_at,
    latest.finished_at                  AS latest_run_finished_at,
    latest.items_new                    AS latest_items_new,
    COALESCE(err7.error_count, 0)       AS errors_last_7_days
FROM sources s
LEFT JOIN LATERAL (
    SELECT cr.*
    FROM collection_runs cr
    WHERE cr.source_id = s.id
    ORDER BY cr.started_at DESC
    LIMIT 1
) latest ON true
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS error_count
    FROM collection_errors ce
    JOIN collection_runs cr2 ON cr2.id = ce.collection_run_id
    WHERE cr2.source_id = s.id
      AND ce.occurred_at > now() - INTERVAL '7 days'
) err7 ON true;

COMMIT;

-- =============================================================================
-- Seed: the 8 fixed threat categories (safe to re-run; no-op if already present)
-- =============================================================================
INSERT INTO categories (code, label) VALUES
    ('chemical',     'Chemical'),
    ('biological',   'Biological'),
    ('radiological', 'Radiological'),
    ('nuclear',      'Nuclear'),
    ('explosive',    'Explosive'),
    ('cyber',        'Cyber'),
    ('health',       'Health'),
    ('industry',     'Industry')
ON CONFLICT (code) DO NOTHING;
