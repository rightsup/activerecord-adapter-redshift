# Agent instructions

This gem is a thin Redshift adapter for ActiveRecord: `RedshiftAdapter <
PostgreSQLAdapter`, overriding only where Redshift's SQL or catalog differs
(`lib/active_record/connection_adapters/redshift_adapter.rb`). Its consumers
are internal apps that install it from this repo by git tag (or a branch while
a change is in review). It is not published to rubygems.

## Supporting a new Rails version, or fixing a breakage

Follow `MAINTENANCE.md` -- read it before changing `lib/` or the gemspec. It
holds the diagnostic algorithm, the scripts to run for each kind of change
(Rails, Redshift engine, `pg` gem), every override with the Redshift error
that justified it, and the "Supported surface" table of what has been checked
on a real cluster.

The trap it guards against: **PostgreSQL green is not Redshift green.**
PostgreSQL accepts catalog SQL that Redshift rejects, so CI
(`script/verify_postgres_plumbing.rb` on PostgreSQL) can pass while every
model fails on Redshift. That happened with Rails 8's `primary_keys`.

Every new version -- ActiveRecord, Redshift engine patch, or `pg` gem -- is
done only when **all three** scripts in `script/` pass (the two Redshift ones
against a real cluster, or with `PRINT_SQL=1` statements run in its SQL
editor), even if nothing looks broken. Then update the "Redshift SQL: what
works and what doesn't" tables in `MAINTENANCE.md`: they are a snapshot, not
a guarantee.

When you add or change an override:
- Copy the upstream method from the exact Rails version's source, change only
  what Redshift needs, and comment the Redshift error that forced it.
- Add the method to `OVERRIDDEN_METHODS` in `script/verify_postgres_plumbing.rb`.
- Update the tables in `MAINTENANCE.md`.

## Working with a real cluster

- Keep `REDSHIFT_URL` and every connection detail out of agent
  conversations, commits and PRs; the scripts print only pass/fail.
- Run the scripts against scratch data only: they create and drop tables.
- Scripts that print anything must redact the URL's host, user and password
  (see `verify_redshift_introspection.rb`).

## Releasing

1. Bump `s.version` in the gemspec (semver; dropping a Rails version is major).
   Supporting a new Rails minor also means raising the `activerecord` upper
   bound -- only after the re-tests pass.
2. Merge to `master`, then tag `vX.Y.Z` on `master`.
3. Repoint each consuming app's `Gemfile` to the new tag and refresh its
   lockfile.
4. Delete a feature branch only after no app still pins it: a squash merge
   leaves a branch-pinned SHA unreachable once the branch is gone.

Confirm with the owner before any commit, push, tag or PR comment, and draft
PR text in chat first.
