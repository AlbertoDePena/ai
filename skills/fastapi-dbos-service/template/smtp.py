"""
SMTP email sending.

Local: points at the Mailpit container (SMTP on :1025, web UI on :8025), which
captures mail instead of delivering it - open http://localhost:8025 to see what
was sent. Mailpit needs no auth or TLS.

Prod: point SMTP_HOST/SMTP_PORT at Amazon SES's SMTP endpoint (or any SMTP
relay), set SMTP_USERNAME/SMTP_PASSWORD (SES SMTP credentials), and set
SMTP_USE_TLS=true. Same code path - Mailpit and SES both just speak SMTP.

Named smtp.py, not email.py, because email.py would shadow the stdlib `email`
package that smtplib depends on.
"""

from __future__ import annotations

import logging
import os
import smtplib
import ssl
from email.message import EmailMessage

logger = logging.getLogger(__name__)

SMTP_HOST = os.environ.get("SMTP_HOST", "mailpit")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "1025"))
SMTP_USERNAME = os.environ.get("SMTP_USERNAME")  # unset for Mailpit
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD")
SMTP_USE_TLS = os.environ.get("SMTP_USE_TLS", "false").lower() == "true"
EMAIL_FROM = os.environ.get("EMAIL_FROM", "orders@example.com")


def send_email(to: str, subject: str, body: str) -> None:
    """Send a plaintext email. Raises on failure so the caller (a DBOS step)
    can retry - SMTP_USE_TLS/credentials are only needed for real relays like
    SES; Mailpit works with the defaults."""
    msg = EmailMessage()
    msg["From"] = EMAIL_FROM
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as server:
        if SMTP_USE_TLS:
            server.starttls(context=ssl.create_default_context())
        if SMTP_USERNAME and SMTP_PASSWORD:
            server.login(SMTP_USERNAME, SMTP_PASSWORD)
        server.send_message(msg)

    logger.info("Sent '%s' email to %s via %s:%s", subject, to, SMTP_HOST, SMTP_PORT)
