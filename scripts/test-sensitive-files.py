#!/usr/bin/env python3
import importlib.util
import io
from pathlib import Path
import zipfile

spec = importlib.util.spec_from_file_location("guard", Path(__file__).with_name("check-sensitive-files.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
checks = 0

def check(condition, label):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print("PASS:", label)

for name in [".env", "credentials/account.json", "telegram-data/profile", "message.db", "message.db-wal", "account.session", "native/build/output", "codex-clipboard-example.png", "telegram.local.json"]:
    check(bool(guard.violations(name, b"fixture")), "private artifact is blocked: " + name)
fake_hash = b"0123456789abcdef" * 2
check(bool(guard.violations("settings.json", b'{"api_hash":"' + fake_hash + b'"}')), "API hash literals are blocked")
check(bool(guard.violations("notes.md", b"tg://login?token=" + b"A" * 43)), "login QR token literals are blocked")
check(not guard.violations("test.json", b'{"api_hash":"' + b"0" * 32 + b'"}'), "explicit all-zero synthetic fixture is allowed")
check(bool(guard.violations("notes.md", b"-----BEGIN " + b"PRIVATE KEY-----")), "private keys are blocked")
check(not guard.violations("native/Sources/Telegram/TelegramSecurity.swift", b'object["api_hash"] = credentials.apiHash'), "code using runtime credentials is allowed")
archive = io.BytesIO()
with zipfile.ZipFile(archive, "w") as z:
    z.writestr("project/credentials/key.json", b"fixture")
check(bool(guard.violations("release-source.zip", archive.getvalue())), "private artifacts inside source ZIPs are blocked")
check(not guard.violations(".env.example", b"API_ID=\nAPI_HASH=\n"), "empty configuration template is allowed")
print("SUCCESS:", checks, "sensitive-file guard checks; synthetic data only")
