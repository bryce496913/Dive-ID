# Candidate Retrieval Benchmark

The unchanged 100-case Caribbean fixture was run on Linux before and after enabling
the lexical candidate pool. The current eight-species pack fits entirely within the
default pool, so this architecture pass intentionally preserves the baseline metrics.

| Engine | Top 1 | Top 3 | Top 10 | Correct no-match |
| --- | ---: | ---: | ---: | ---: |
| Legacy structured engine | 44/80 | 59/80 | 64/80 | 20/20 |
| BM25 retrieval + structured reranking | 44/80 | 59/80 | 64/80 | 20/20 |

Representative lexical retrieval checks use the production canonical documents:

- `fish with beak-like teeth grazing reef` retrieves Stoplight Parrotfish.
- `long streamlined predator with large jaw` retrieves Great Barracuda.
- `flat animal with white dots and whip-like tail` retrieves Spotted Eagle Ray.

These checks concern entry into the candidate pool. Final ordering, confidence, visible
evidence, conflicts, and explanations remain the responsibility of the structured
biological ranker.
