---
name: db_migration
description: Database migration guide
---

# Database Migration Guide

Follow these steps for schema changes:

1. Create migration file: `alembic revision --autogenerate -m "description"`
2. Review generated SQL carefully before applying
3. Run on staging first: `alembic upgrade head`
4. If migration fails, execute deploy_rollback to restore the previous app version
5. Alert the team via slack_notify before and after production migrations
6. For large datasets, run in batches to avoid replication lag

Always test rollback: `alembic downgrade -1`
