#!/usr/bin/env python3
"""Step 2 (robust): complete Telegram login with timeout handling."""
import asyncio, configparser, os, sys

BASE = os.path.dirname(os.path.abspath(__file__))

def load_conf():
    c = configparser.ConfigParser()
    with open(os.path.join(BASE, "tg-api.conf")) as f:
        content = "[tg]\n" + f.read()
    c.read_string(content)
    return c["tg"]["api_id"], c["tg"]["api_hash"], c["tg"]["phone"]

async def main(code):
    from telethon import TelegramClient
    import os as _os
    from urllib.parse import urlparse
    api_id, api_hash, phone = load_conf()
    # MTProto direct TCP is blocked by egress; route via HTTP proxy
    proxy = None
    pu = _os.environ.get("HTTPS_PROXY", "")
    if pu:
        p = urlparse(pu)
        proxy = ("http", p.hostname, p.port or 3128, True, p.username, p.password)
    client = TelegramClient(
        os.path.join(BASE, "gladis.session"), int(api_id), api_hash,
        proxy=proxy, connection_retries=3, retry_delay=2, timeout=20,
    )
    try:
        await asyncio.wait_for(client.connect(), timeout=30)
    except asyncio.TimeoutError:
        print("CONNECT_TIMEOUT"); return
    try:
        if await client.is_user_authorized():
            print("ALREADY_AUTHORIZED")
        else:
            await asyncio.wait_for(client.sign_in(phone, code), timeout=30)
            print("AUTHORIZED_OK" if await client.is_user_authorized() else "SIGNIN_FAILED")
        me = await client.get_me()
        print(f"LOGGED_IN_AS={me.first_name} id={me.id}")
    except asyncio.TimeoutError:
        print("SIGNIN_TIMEOUT")
    except Exception as e:
        print(f"ERROR: {type(e).__name__}: {e}")
    finally:
        await client.disconnect()

asyncio.run(main(sys.argv[1]))
