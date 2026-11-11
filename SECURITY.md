# Security policy

**Never share an Apple Notes store, Flashnote database, ENEX export, or its generated manifest publicly.** These may contain private content.

The Flashnote converter reads its source SQLite database in read-only mode and never uploads content. Native Notes restoration replaces the user's local store only after explicit confirmation and saving a full backup. It is not a safe merge operation and can interfere with iCloud-backed notes if syncing is active.

To report a security issue, use a private channel with the repository maintainer rather than posting a real backup or notes content in a public GitHub issue. Reproduce problems using synthetic data if possible.
