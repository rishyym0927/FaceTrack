"""Regenerate the current public API contract without database or Auth network access."""

import asyncio
import json
from pathlib import Path

from app.main import create_app


async def main():
    app = create_app()
    async with app.router.lifespan_context(app):
        target = Path(__file__).resolve().parents[3] / "contracts/openapi.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(app.openapi(), indent=2) + "\n")
    print("API contract exported to contracts/openapi.json.")


if __name__ == "__main__":
    asyncio.run(main())
