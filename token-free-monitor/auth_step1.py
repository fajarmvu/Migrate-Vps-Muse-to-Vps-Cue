#!/usr/bin/env python3
"""Step 1: request Telegram login code for Fajar's account."""
import asyncio, configparser, os, sys

BASE = os.path.dirname(os.path.abspath(__file__))

def load_conf():
    c = configparser.ConfigParser()
    # config file has no section header; add one
    with open(os.path.join(BASE, "tg-api.conf")) as f:
        content = "[tg]\n" + f.read()
    c.read_string(content)
    return c["tg"]["api_id"], c["tg"]["api_hash"], c["tg"]["phone"]

async def main():
    from telethon import TelegramClient
    import os as _os
    api_id, api_hash, phone = load_conf()
    # Route MTProto through the egress HTTP proxy (direct TCP is blocked)
    proxy_url = _os.environ.get("HTTPS_PROXY", "")
    proxy = None
    if proxy_url:
        from urllib.parse import urlparse
        p = urlparse(proxy_url)
        proxy = ("http", p.hostname, p.port or 3128, True, p.username, p.password)
    client = TelegramClient(os.path.join(BASE, "gladis.session"), int(api_id), api_hash, proxy=proxy)
    await client.connect()
    if await client.is_user_authorized():
        print("ALREADY_AUTHORIZED")
    else:
        await client.send_code_request(phone)
        print("CODE_SENT")
    await client.disconnect()

asyncio.run(main())
