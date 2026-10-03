# AGENTS.md

Instructions for coding agents working on this repository.

## Working files go in work/

An agent's own temp directory is not on the host's filesystem, so a path
reported from there is one the user cannot open. Downloads, disk images, test
harnesses and captured logs belong in `work/`: the directory is committed, its
contents are gitignored, and everything in it can be deleted at any time.

Two kinds of file stay out of it:

- **Secrets** — passwords, private keys, Wi-Fi credentials. `work/` is plain,
  unencrypted and inside a repository that is published.
- **Files the work keeps needing** — they go into the repository, unless they
  are secrets or may not be redistributed (vendor firmware, for example);
  those stay where the tool's README says.
