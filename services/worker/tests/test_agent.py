import httpx
import pytest

from facetrack_worker.agent import CREDENTIAL_REJECTED, WAITING, failure_notice


def status_error(code):
    request = httpx.Request("POST", "http://api:8000/internal/v1/jobs/claim")
    return httpx.HTTPStatusError("x", request=request, response=httpx.Response(code, request=request))


def test_rejected_credential_is_named_and_backs_off():
    for code in (401, 403):
        assert failure_notice(status_error(code)) == (CREDENTIAL_REJECTED, 60)


def test_network_and_server_errors_keep_waiting():
    request = httpx.Request("POST", "http://api:8000/internal/v1/jobs/claim")
    assert failure_notice(httpx.ConnectError("refused", request=request)) == (WAITING, 5)
    assert failure_notice(status_error(503)) == (WAITING, 5)
    assert failure_notice(ConnectionError()) == (WAITING, 5)


class FakeResponse:
    def __init__(self, status, body=None):
        self.status_code = status
        self.body = body or {}

    def json(self):
        return self.body


@pytest.fixture(autouse=True)
def idle_worker(monkeypatch):
    from facetrack_worker import agent

    monkeypatch.setattr(agent, "backlog", lambda: 0)
    agent._noticed.clear()


def test_busy_worker_is_not_given_more_leases(monkeypatch):
    from facetrack_worker import agent

    agent.PENDING.clear()
    calls = []
    monkeypatch.setattr(agent, "backlog", lambda: 1)
    monkeypatch.setattr(agent, "api", lambda c, m, p: calls.append(p) or FakeResponse(204))
    assert agent.cycle(None, 1e18) == (1e18, 1)
    assert calls == []  # no claim while a job is queued or running


def test_failing_reconcile_does_not_block_claiming(monkeypatch, capsys):
    from facetrack_worker import agent

    calls, sent = [], []

    def api(client, method, path):
        calls.append(path)
        if path.endswith("reconcile"):
            raise status_error(500)
        return FakeResponse(200, {"id": "job", "lease_epoch": 3})

    monkeypatch.setattr(agent, "api", api)
    monkeypatch.setattr(agent.app, "send_task", lambda name, args: sent.append(args))
    maintenance, delay = agent.cycle(None, 0)
    assert calls == ["/internal/v1/maintenance/reconcile", "/internal/v1/jobs/claim"]
    assert sent == [["job", 3]] and delay == 2 and maintenance > 0
    assert agent.MAINTENANCE_FAILED in capsys.readouterr().out
    # Not retried on every claim round; the next attempt waits for the next minute.
    agent.cycle(None, maintenance)
    assert calls[-1] == "/internal/v1/jobs/claim" and len(calls) == 3


def test_broker_outage_waits_instead_of_crashing(monkeypatch, capsys):
    from kombu.exceptions import OperationalError

    from facetrack_worker import agent

    def refuse(name, args):
        raise OperationalError("Error 111 connecting to redis:6379. Connection refused.")

    claimed = FakeResponse(200, {"id": "j", "lease_epoch": 1})
    monkeypatch.setattr(agent, "api", lambda client, method, path: claimed)
    monkeypatch.setattr(agent.app, "send_task", refuse)
    assert agent.cycle(None, 1e18)[1] == 5
    assert agent.BROKER_WAITING in capsys.readouterr().out


def test_failed_handoff_is_retried_on_the_same_lease(monkeypatch):
    from kombu.exceptions import OperationalError

    from facetrack_worker import agent

    agent.PENDING.clear()
    claims, sent, down = [], [], [True]

    def api(client, method, path):
        claims.append(path)
        return FakeResponse(200, {"id": "j", "lease_epoch": 1})

    def send(name, args):
        if down[0]:
            raise OperationalError("refused")
        sent.append(args)

    monkeypatch.setattr(agent, "api", api)
    monkeypatch.setattr(agent.app, "send_task", send)
    agent.cycle(None, 1e18)
    down[0] = False
    agent.cycle(None, 1e18)
    assert sent == [["j", 1]] and len(claims) == 1  # no second claim, no extra attempt
    assert not agent.PENDING


def test_malformed_claim_body_does_not_crash(monkeypatch, capsys):
    from facetrack_worker import agent

    agent.PENDING.clear()
    monkeypatch.setattr(agent, "api", lambda c, m, p: FakeResponse(200, {"unexpected": 1}))
    assert agent.cycle(None, 1e18)[1] == 5
    assert "Unexpected claim response" in capsys.readouterr().out


def test_lease_missing_fields_is_not_remembered(monkeypatch):
    from facetrack_worker import agent

    agent.PENDING.clear()
    monkeypatch.setattr(agent, "api", lambda c, m, p: FakeResponse(200, {"id": "j"}))
    assert agent.cycle(None, 1e18)[1] == 5
    assert not agent.PENDING  # the next round claims normally instead of stalling 90 s
