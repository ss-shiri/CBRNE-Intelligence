# CBRNE Intelligence Reading Room

## Architecture and Implementation Strategy

This document defines the technical architecture for an evidence-centric CBRNE intelligence platform designed for large-scale open-source collection, provenance preservation, entity extraction, and optional AI-assisted analytical workflows.

The system is designed around three core principles:

1. **Evidence preservation**
   
   Original source material and collection metadata are preserved separately from derived analytical products.

2. **Reproducible intelligence workflows**
   
   Every transformation, enrichment process, and analytical output should maintain provenance, versioning, and traceability.

3. **Modular intelligence processing**

   Collection, enrichment, and analytical assessment are implemented as independent components, allowing each layer to operate independently and be validated separately.

---

## Architecture Constraints

### 1. Collection Frequency and Scheduling

GitHub Actions scheduled workflows are unsuitable for high-frequency monitoring. They operate on a best-effort basis, with practical scheduling limitations and possible execution delays.

High-frequency monitoring should therefore use dedicated scheduling infrastructure:

| Tier | Frequency | Recommended Runtime | Purpose |
|---|---|---|---|
| Tier 0 | 1-5 minutes | Cloudflare Workers, VPS scheduler | Critical alerts and priority feeds |
| Tier 1 | 15 minutes | Persistent worker service | Agency news and media monitoring |
| Tier 2 | 1-6 hours | Worker service or GitHub Actions | Institutional reporting |
| Tier 3 | 12-24 hours | GitHub Actions | Academic databases, publications, patents |

The repository remains the software source of truth, while operational data is stored in PostgreSQL.

---

## Evidence and Analysis Separation

The platform separates collected evidence from analytical interpretation.

The database design intentionally separates:

- `raw_documents`
- `articles`
- `article_versions`

from:

- `assessments`

AI-generated products never modify original evidence records.

Every analytical output should include:

- producing model/system
- prompt or processing version
- timestamp
- uncertainty or information gaps

This prevents analytical outputs from becoming indistinguishable from source evidence.

---

## Development Scope

The complete platform includes:

- multi-source ingestion
- CBRNE entity extraction
- semantic search
- country and domain intelligence views
- provenance tracking
- optional AI-assisted analysis

The implementation should proceed through validated vertical slices rather than attempting the complete system in a single development stage.

The first operational milestone is:

1. Database deployment
2. Source registry
3. RSS and scientific database collectors
4. Deduplication and version tracking
5. Search API
6. Reader interface
7. Collection monitoring dashboard

This establishes the core intelligence pipeline before additional capabilities are added.
