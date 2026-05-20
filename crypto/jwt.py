'''
A simple implementation of JSON Web Tokens (JWT) using HMAC-SHA256.
JWT主要是用来保证消息的完整性, 如果采用对称加密算法的话, 验证会非常快。

JWT的结构是由三部分组成的:
- Header
- Payload: Header和Payload都是JSON格式的数据, 经过Base64URL编码后用点号分隔开来
- Signature: 是对Header和Payload进行签名(其实就是keyed-hash之类的堆成加密)生成的, 用于验证数据的完整性。

> 注意机密性需要靠https来保证, 因为JWT本身是明文的, 任何人都可以解密出Header和Payload的内容, 但是没有secret是无法伪造出合法的Signature的。 
'''
import base64
import hashlib
import hmac
import json
import time


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def encode(payload: dict, secret: str, algorithm: str = "HS256") -> str:
    if algorithm != "HS256":
        raise ValueError(f"unsupported algorithm: {algorithm}")

    header = {"alg": "HS256", "typ": "JWT"}
    header_b64 = _b64url_encode(json.dumps(header, separators=(",", ":"), sort_keys=True).encode())
    payload_b64 = _b64url_encode(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())

    signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
    signature = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    signature_b64 = _b64url_encode(signature)

    return f"{header_b64}.{payload_b64}.{signature_b64}"


def decode(token: str, secret: str, verify_exp: bool = True) -> dict:
    try:
        header_b64, payload_b64, signature_b64 = token.split(".")
    except ValueError:
        raise ValueError("malformed token")

    header = json.loads(_b64url_decode(header_b64))
    if header.get("alg") != "HS256":
        raise ValueError(f"unsupported algorithm: {header.get('alg')}")

    signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
    expected_sig = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    actual_sig = _b64url_decode(signature_b64)
    if not hmac.compare_digest(expected_sig, actual_sig):
        raise ValueError("invalid signature")

    payload = json.loads(_b64url_decode(payload_b64))

    if verify_exp and "exp" in payload:
        if int(time.time()) >= int(payload["exp"]):
            raise ValueError("token expired")

    return payload


if __name__ == "__main__":
    secret = "my-secret"
    token = encode({"sub": "alice", "exp": int(time.time()) + 60}, secret)
    print("token:", token)
    print("decoded:", decode(token, secret))
