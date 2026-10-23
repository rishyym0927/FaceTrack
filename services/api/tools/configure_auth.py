"""Save the project's publishable API key without printing or shell-history exposure."""

import getpass
from pathlib import Path

from dotenv import set_key


def main():
    target = Path(__file__).resolve().parents[1] / ".env"
    if not target.is_file() or target.is_symlink():
        raise SystemExit("Initialize the private backend environment first.")
    key = getpass.getpass("Supabase publishable key (hidden): ").strip()
    if not key.startswith("sb_publishable_") or len(key) < 25 or any(c.isspace() for c in key):
        raise SystemExit(
            "Expected the sb_publishable_ key from API Keys; no settings were changed."
        )
    target.chmod(0o600)
    set_key(target, "SUPABASE_PUBLISHABLE_KEY", key)
    target.chmod(0o600)
    print("Publishable key saved privately. Real login verification is still required.")


if __name__ == "__main__":
    main()
