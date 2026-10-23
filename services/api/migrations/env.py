import os
from pathlib import Path

from alembic import context
from dotenv import load_dotenv
from sqlalchemy import create_engine, pool

from app.models import metadata

load_dotenv(Path(__file__).parents[1] / ".env")
url = os.environ.get("MIGRATION_DATABASE_URL")
if not url:
    raise RuntimeError("Set MIGRATION_DATABASE_URL in the private API environment.")
engine = create_engine(url, poolclass=pool.NullPool)
with engine.connect() as connection:
    context.configure(connection=connection, target_metadata=metadata)
    with context.begin_transaction():
        context.run_migrations()
