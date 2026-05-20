"""
解释下为什么JWT要采用HMAC-SHA256这种结构来生成Signature, 而不是直接用SHA256(key || message)来生成MAC。
因为直接采用这种方式在如下问题:
Length-extension attack against naive MAC = sha256(key || message).

> 实际上长度拓展攻击也主要在用裸 hash 当 MAC」这一种场景下有实际危害。

Given (msg, tag = sha256(key || msg)) and len(key), an attacker can compute
sha256(key || msg || glue_padding || extension) for any chosen extension —
without knowing key.

This works because SHA-256 (Merkle-Damgard) exposes its full internal state
as the digest: 32-byte output = 8 x uint32 state words. Anyone holding the
tag can resume hashing from that state.

Python's hashlib does not let us inject state, so we implement SHA-256 from
scratch with a `resume_state` / `prefix_len` hook.

sha256_state = tag = sha256(key || msg || padding to 64 bytes)
forged_tag = sha256(extension, resume_state=tag_as_state, prefix_len=len(key) + len(msg) + len(padding)) 
           = sha256((key || msg || padding) || extension) 
           # 前三项正好padding到64字节边界, 保证state内部状态与原tag对上, 然后把extension当做新的消息继续hash下去
forged_msg = (msg || padding) || extension

"""

import hashlib
import struct


K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

H0 = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]


def _rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF


def _compress(state, block):
    w = list(struct.unpack(">16I", block))
    for i in range(16, 64):
        s0 = _rotr(w[i-15], 7) ^ _rotr(w[i-15], 18) ^ (w[i-15] >> 3)
        s1 = _rotr(w[i-2], 17) ^ _rotr(w[i-2], 19) ^ (w[i-2] >> 10)
        w.append((w[i-16] + s0 + w[i-7] + s1) & 0xFFFFFFFF)

    a, b, c, d, e, f, g, h = state
    for i in range(64):
        S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
        ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g)
        t1 = (h + S1 + ch + K[i] + w[i]) & 0xFFFFFFFF
        S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
        mj = (a & b) ^ (a & c) ^ (b & c)
        t2 = (S0 + mj) & 0xFFFFFFFF
        h = g
        g = f
        f = e
        e = (d + t1) & 0xFFFFFFFF
        d = c
        c = b
        b = a
        a = (t1 + t2) & 0xFFFFFFFF
    return [(x + y) & 0xFFFFFFFF for x, y in zip(state, (a, b, c, d, e, f, g, h))]


def md_padding(total_bytes: int) -> bytes:
    """SHA-256 (Merkle-Damgard) padding for a message of `total_bytes` bytes."""
    pad_len = (55 - total_bytes) % 64
    return b"\x80" + b"\x00" * pad_len + struct.pack(">Q", total_bytes * 8)


# hashlib 的 API 没有办法把外部给定的 32 字节当成初始状态注入进去，所以这里只能手写
def sha256(msg: bytes, resume_state=None, prefix_len: int = 0) -> bytes:
    """SHA-256 with an optional `resume_state` (8 uint32s) and `prefix_len`
    (bytes already hashed before this call). With defaults, behaves like
    hashlib.sha256(msg).digest()."""
    state = list(resume_state) if resume_state is not None else list(H0)
    padded = msg + md_padding(prefix_len + len(msg))
    for i in range(0, len(padded), 64):
        state = _compress(state, padded[i:i+64])
    return struct.pack(">8I", *state)


def attack():
    # --- Server side ---
    secret = b"super-secret-key"           # attacker does NOT know this
    original_msg = b"amount=100&to=alice"
    tag = sha256(secret + original_msg)    # server publishes (msg, tag)

    # Sanity-check our SHA-256 against stdlib
    assert hashlib.sha256(secret + original_msg).digest() == tag

    print("[server] msg :", original_msg)
    print("[server] tag :", tag.hex())

    # --- Attacker side ---
    # Attacker knows: original_msg, tag, and guesses len(secret).
    # Goal: forge a valid tag for (original_msg || glue || extension).
    key_len_guess = len(secret)
    extension = b"&admin=true"

    # 1. Treat the tag as SHA-256 internal state (8 x uint32 big-endian).
    resumed_state = list(struct.unpack(">8I", tag))

    # 2. Reconstruct the glue padding that the server's SHA-256 appended
    #    internally after `secret || original_msg`.
    glue = md_padding(key_len_guess + len(original_msg))

    # 3. Continue hashing `extension` from the resumed state, telling our
    #    sha256() that `prefix_len` bytes were already consumed — this
    #    makes the final length field in the padding come out right.
    prefix_len = key_len_guess + len(original_msg) + len(glue)
    forged_tag = sha256(extension, resume_state=resumed_state, prefix_len=prefix_len)

    forged_msg = original_msg + glue + extension

    print("\n[attacker] forged_msg :", forged_msg)
    print("[attacker] forged_tag :", forged_tag.hex())

    # --- Server re-verifies the forged message ---
    expected_tag = hashlib.sha256(secret + forged_msg).digest()
    print("\n[server]   expected  :", expected_tag.hex())
    print("\nattack succeeded?", forged_tag == expected_tag)


if __name__ == "__main__":
    attack()
