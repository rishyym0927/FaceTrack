"""Configure the Storage secret and separate template keyring without echoing secrets."""

import getpass
import secrets
from pathlib import Path

from dotenv import dotenv_values, set_key


def main():
    target = Path(__file__).resolve().parents[1] / ".env"
    if not target.is_file() or target.is_symlink():
        raise SystemExit("Configure the backend first.")
    key = getpass.getpass("Supabase secret key (hidden; sb_secret_): ").strip()
    if not key.startswith("sb_secret_") or any(c.isspace() for c in key) or len(key) < 25:
        raise SystemExit("Expected a project secret key; no settings changed.")
    existing = dotenv_values(target)
    target.chmod(0o600)
    set_key(target, "SUPABASE_STORAGE_SECRET", key)
    if not existing.get("TEMPLATE_KEYS"):
        import json

        set_key(target, "TEMPLATE_KEYS", json.dumps({"v1": secrets.token_hex(32)}))
        set_key(target, "TEMPLATE_KEY_ID", "v1")
    target.chmod(0o600)
    print(
        "Private Storage/template configuration saved. No secret was printed. Restart API before live checks."
    )


if __name__ == "__main__":
    main()
