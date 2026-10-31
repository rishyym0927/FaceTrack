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
