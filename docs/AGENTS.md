# Documentation Instructions

These instructions apply below `docs/` in addition to the repository root
`AGENTS.md`.

- `README.md` is the authoritative documentation router. Add, remove, or move a
  specialist document only together with the corresponding routing entry.
- Stable product behavior and reusable engineering rules belong under
  `architecture/`.
- Repeatable development, build, validation, installation, and release
  procedures belong under `workflows/`.
- `roadmaps/` owns current implementation status, remaining work, acceptance
  debt, validation evidence, and the next resume point. It must not become an
  alternate specification for stable product contracts.
- Keep one authoritative owner for each rule. Other documents may summarize and
  link, but should not redefine the same contract.
- Do not split a document merely because it is long. Split when independent
  tasks would otherwise require reading mostly unrelated material or when
  ownership becomes unclear.
- Move completed debugging narratives and obsolete internal layouts to Git
  history instead of accumulating them in active roadmap prose.
- While the project remains unpublished and local history may be rewritten,
  do not embed Sonbal or dependency Git commit identifiers in active
  documentation. Use release identities, acceptance state, and artifact
  evidence instead. Obtain exact revisions from generated package/validation
  provenance when needed; pre-publication Git history may be rewritten.
- Prefer names and locations that reveal when a document should be read.
