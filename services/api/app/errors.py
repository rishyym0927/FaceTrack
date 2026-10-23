class APIError(Exception):
    def __init__(self, status: int, code: str, message: str, *, retryable=False, commit=False):
        self.status, self.code, self.message = status, code, message
        self.retryable, self.commit = retryable, commit
        super().__init__(message)
