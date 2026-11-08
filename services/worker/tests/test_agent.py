import httpx

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
