class SpikeError(Exception):
    """Safe errors contain codes and instructions, never biometric payloads."""

    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)
