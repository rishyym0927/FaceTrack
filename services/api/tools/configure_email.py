"""Save optional development Resend configuration without putting secrets in chat/history."""

import getpass
from pathlib import Path
from urllib.parse import urlparse

from dotenv import set_key


def main():
    target = Path(__file__).parents[1] / ".env"
    if not target.is_file() or target.is_symlink():
        raise SystemExit("Configure the existing backend environment first.")
    key = getpass.getpass("Resend API key (hidden): ").strip()
    sender = input("Verified permitted sender address: ").strip()
    url = input("Teacher app base URL [http://localhost:5300]: ").strip() or "http://localhost:5300"
    parsed = urlparse(url)
    if (
        not key.startswith("re_")
        or "@" not in sender
        or "\n" in sender
        or parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.query
        or parsed.fragment
        or parsed.username
    ):
        raise SystemExit("Invalid configuration; nothing saved.")
    if parsed.scheme == "http" and parsed.hostname not in ("localhost", "127.0.0.1"):
        raise SystemExit("Use HTTPS outside loopback.")
    target.chmod(0o600)
    for name, value in [
        ("RESEND_API_KEY", key),
        ("RESEND_FROM", sender),
        ("FACULTY_REPORT_URL", url),
    ]:
        set_key(target, name, value)
    target.chmod(0o600)
    print(
        "Email configuration saved privately. Restart API. Sending permissions and real recipient/inbox acceptance are not yet verified."
    )


if __name__ == "__main__":
    main()
