"""Live hosted Auth + local API smoke check using controlled seeded demo accounts."""

import argparse
import getpass
import json
from pathlib import Path
from uuid import uuid4

import httpx

from app.config import Settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--users-file", required=True, type=Path)
    parser.add_argument("--ids-file", required=True, type=Path)
    parser.add_argument("--api-url", default="http://127.0.0.1:8000")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if args.api_url != "http://127.0.0.1:8000":
        parser.error("This development smoke tool targets the loopback API on port 8000 only.")
    settings = Settings()
    users, ids = json.loads(args.users_file.read_text()), json.loads(args.ids_file.read_text())
    tokens, checks = {}, {}
    with httpx.Client(timeout=15, follow_redirects=False) as client:
        for label in ("teacher", "unassigned", "student1", "other_teacher"):
            password = getpass.getpass(f"Controlled demo password for {label}: ")
            response = client.post(
                settings.supabase_url + "/auth/v1/token?grant_type=password",
                headers={"apikey": settings.supabase_publishable_key.get_secret_value()},
                json={"email": users[label]["email"], "password": password},
            )
            if response.status_code != 200:
                raise RuntimeError(
                    f"Hosted login failed for {label} (HTTP {response.status_code}); no token was saved."
                )
            payload = response.json()
            if payload["user"]["id"] != users[label]["id"]:
                raise RuntimeError("Auth account does not match seeded identity.")
            tokens[label] = payload["access_token"]
        checks["hosted_logins"] = True

        def call(method, path, label="teacher", expected=200, body=None, version=None):
            headers = {
                "Authorization": "Bearer " + tokens[label],
                "X-Institute-ID": ids["institute"],
                "Idempotency-Key": str(uuid4()),
            }
            if version is not None:
                headers["If-Match"] = str(version)
            result = client.request(method, args.api_url + path, headers=headers, json=body)
            if result.status_code != expected:
                raise RuntimeError(
                    f"Live check failed: {method} {path} returned HTTP {result.status_code}, expected {expected}."
                )
            return result.json()

        call("GET", "/health/ready")
        call("GET", "/v1/me")
        checks["real_token_verification"] = True
        call("POST", "/v1/identity/claim", "student1", 201, {"enrollment_number": "0001"})
        checks["confirmed_email_identity_claim"] = True
        offering = call("GET", f"/v1/offerings/{ids['offering']}")
        code = call(
            "POST",
            f"/v1/offerings/{ids['offering']}/join-code",
            expected=201,
            version=offering["version"],
        )
        enrollment = call(
            "POST", "/v1/enrollment-requests", "student1", 201, {"join_code": code["code"]}
        )
        call("GET", f"/v1/offerings/{ids['offering']}/roster", "student1", 404)
        call("GET", f"/v1/offerings/{ids['offering']}/roster", "unassigned", 404)
        call("GET", f"/v1/offerings/{ids['offering']}", "other_teacher", 403)
        checks["student_roster_assignment_and_tenant_denials"] = True
        result = call(
            "PATCH",
            f"/v1/offerings/{ids['offering']}/enrollments/{enrollment['id']}",
            body={"status": "active", "reason": "Controlled hosted smoke verification"},
            version=enrollment["version"],
        )
        checks["teacher_approval"] = result["status"] == "active"
    args.out.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    args.out.write_text(
        json.dumps({"suite": "hosted-foundation-smoke", "checks": checks}, indent=2)
    )
    args.out.chmod(0o600)
    print(
        "Live hosted foundation smoke passed; sanitized result saved privately. Tokens were not saved."
    )


if __name__ == "__main__":
    main()
