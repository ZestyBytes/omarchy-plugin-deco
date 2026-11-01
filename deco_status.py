#!/usr/bin/env python3
"""
Headless helper for the Omarchy bar widget: logs into the Deco, fetches the
client list, and prints one JSON line to stdout. No output to stderr on
success — the widget only cares about stdout.

Config (host/username/password) lives in:
    ~/.local/state/omarchy/deco-mesh/config.json
as plain JSON: {"host": "...", "username": "admin", "password": "..."}
That file is created/edited by the widget's settings screen, not by hand.
"""
import base64
import codecs
import hashlib
import json
import os
import re
import sys

import requests
import urllib3
from Crypto.Cipher import AES, PKCS1_v1_5
from Crypto.PublicKey import RSA
from Crypto.Util.Padding import pad, unpad
from Crypto.Util.number import bytes_to_long

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Seconds per HTTPS request. The first login to a Deco X50 can take >5s
# (RSA key exchange on the router), so 5s timed out on real hardware.
REQUEST_TIMEOUT = 20

CONFIG_PATH = os.path.expanduser("~/.local/state/omarchy/deco-mesh/config.json")


class Deco:
    def __init__(self, host, username, password):
        self.host = host
        self.username = username
        self.password = password
        self.stok = ""
        self.sysauth = ""
        self.public_key = None
        self.rsa_seq = ""
        self.aes_key = "1641928074282809"
        self.aes_iv = "1641928074282186"
        self.password_hash = hashlib.md5(
            f"{username}{password}".encode("utf-8")
        ).hexdigest()

    def _base_url(self):
        return f"https://{self.host}/cgi-bin/luci/;stok=/login"

    def login(self):
        referer = f"https://{self.host}/webpages/login.html"

        r = requests.post(
            self._base_url(), params={"form": "keys"},
            data={"operation": "read"}, headers={"Referer": referer},
            timeout=REQUEST_TIMEOUT, verify=False,
        )
        pw_key = r.json()["result"]["password"]

        r = requests.post(
            self._base_url(), params={"form": "auth"},
            data={"operation": "read"}, headers={"Referer": referer},
            timeout=REQUEST_TIMEOUT, verify=False,
        )
        auth_key = r.json()["result"]["key"]
        self.rsa_seq = r.json()["result"]["seq"]

        n = bytes_to_long(bytes.fromhex(pw_key[0]))
        e = bytes_to_long(bytes.fromhex(pw_key[1]))
        pw_encryptor = PKCS1_v1_5.new(RSA.construct((n, e)))
        password_hex = codecs.encode(
            pw_encryptor.encrypt(self.password.encode("utf-8")), "hex"
        ).decode("utf-8").upper()

        auth_data = json.dumps({
            "params": {"password": password_hex},
            "operation": "login",
        })
        cipher = AES.new(self.aes_key.encode(), AES.MODE_CBC, self.aes_iv.encode())
        ciphertext_b64 = base64.b64encode(cipher.encrypt(pad(auth_data.encode(), 16)))

        sign_str = "k={}&i={}&h={}&s={}".format(
            self.aes_key, self.aes_iv, self.password_hash,
            self.rsa_seq + len(ciphertext_b64),
        )
        n = bytes_to_long(bytes.fromhex(auth_key[0]))
        e = bytes_to_long(bytes.fromhex(auth_key[1]))
        self.public_key = RSA.construct((n, e))
        sign_encryptor = PKCS1_v1_5.new(self.public_key)
        if len(sign_str) > 53:
            signed = sign_encryptor.encrypt(sign_str[:53].encode())
            signed += sign_encryptor.encrypt(sign_str[53:].encode())
        else:
            signed = sign_encryptor.encrypt(sign_str.encode())
        signature = codecs.encode(signed, "hex").decode("utf-8")

        r = requests.post(
            self._base_url(), params={"form": "login"},
            data={"sign": signature, "data": ciphertext_b64},
            headers={
                "Referer": f"https://{self.host}/webpages/index.html",
                "Content-Type": "application/json",
                "X-Requested-With": "XMLHttpRequest",
            },
            timeout=REQUEST_TIMEOUT, verify=False,
        )
        result_b64 = r.json().get("data")
        if not result_b64:
            raise RuntimeError(f"Login failed, response: {r.text}")
        decoded = base64.b64decode(result_b64)
        cipher = AES.new(self.aes_key.encode(), AES.MODE_CBC, self.aes_iv.encode())
        plaintext = unpad(cipher.decrypt(decoded), 16)
        result = json.loads(plaintext.decode("utf-8"))
        if result.get("error_code") != 0 or "result" not in result:
            raise RuntimeError(f"Login rejected by Deco: {result}")
        self.stok = result["result"]["stok"]
        self.sysauth = re.search("sysauth=(.*?);", r.headers["set-cookie"]).group(1)

    def _sign_and_encrypt(self, payload):
        encoded = json.dumps(payload)
        cipher = AES.new(self.aes_key.encode(), AES.MODE_CBC, self.aes_iv.encode())
        ciphertext_b64 = base64.b64encode(cipher.encrypt(pad(encoded.encode(), 16)))

        sign_str = f"h={self.password_hash}&s={self.rsa_seq + len(ciphertext_b64)}"
        sign_encryptor = PKCS1_v1_5.new(self.public_key)
        if len(sign_str) > 53:
            signed = sign_encryptor.encrypt(sign_str[:53].encode())
            signed += sign_encryptor.encrypt(sign_str[53:].encode())
        else:
            signed = sign_encryptor.encrypt(sign_str.encode())
        signature = codecs.encode(signed, "hex").decode("utf-8")
        return signature, ciphertext_b64

    def _decrypt(self, data_b64):
        cipher = AES.new(self.aes_key.encode(), AES.MODE_CBC, self.aes_iv.encode())
        plaintext = cipher.decrypt(base64.b64decode(data_b64))
        return json.loads(unpad(plaintext, 16).decode("utf-8"))

    def client_list(self, device_mac="default"):
        url = f"https://{self.host}/cgi-bin/luci/;stok={self.stok}/admin/client"
        signature, data = self._sign_and_encrypt({
            "operation": "read",
            "params": {"device_mac": device_mac},
        })
        r = requests.post(
            url, params={"form": "client_list"},
            data={"sign": signature, "data": data},
            headers={
                "Referer": f"https://{self.host}/webpages/index.html",
                "Origin": f"https://{self.host}",
                "Content-Type": "application/json",
                "X-Requested-With": "XMLHttpRequest",
            },
            cookies={"sysauth": self.sysauth}, timeout=REQUEST_TIMEOUT, verify=False,
        )
        decrypted = self._decrypt(r.json()["data"])
        if decrypted.get("error_code") != 0:
            raise RuntimeError(f"Deco returned an error: {decrypted}")
        return decrypted["result"]["client_list"]

    def device_list(self):
        url = f"https://{self.host}/cgi-bin/luci/;stok={self.stok}/admin/device"
        signature, data = self._sign_and_encrypt({"operation": "read"})
        r = requests.post(
            url, params={"form": "device_list"},
            data={"sign": signature, "data": data},
            headers={
                "Referer": f"https://{self.host}/webpages/index.html",
                "Origin": f"https://{self.host}",
                "Content-Type": "application/json",
                "X-Requested-With": "XMLHttpRequest",
            },
            cookies={"sysauth": self.sysauth}, timeout=REQUEST_TIMEOUT, verify=False,
        )
        decrypted = self._decrypt(r.json()["data"])
        if decrypted.get("error_code") != 0:
            raise RuntimeError(f"Deco returned an error: {decrypted}")
        return decrypted["result"]["device_list"]

    def reboot(self, macs):
        url = f"https://{self.host}/cgi-bin/luci/;stok={self.stok}/admin/device"
        signature, data = self._sign_and_encrypt({
            "operation": "reboot",
            "params": {"mac_list": [{"mac": mac} for mac in macs]},
        })
        r = requests.post(
            url, params={"form": "system"},
            data={"sign": signature, "data": data},
            headers={
                "Referer": f"https://{self.host}/webpages/index.html",
                "Origin": f"https://{self.host}",
                "Content-Type": "application/json",
                "X-Requested-With": "XMLHttpRequest",
            },
            cookies={"sysauth": self.sysauth}, timeout=REQUEST_TIMEOUT, verify=False,
        )
        decrypted = self._decrypt(r.json()["data"])
        if decrypted.get("error_code") != 0:
            raise RuntimeError(f"Deco returned an error: {decrypted}")

    def logout(self):
        url = f"https://{self.host}/cgi-bin/luci/;stok={self.stok}/admin/system"
        requests.post(
            url, params={"form": "logout", "operation": "write"},
            headers={"Referer": f"https://{self.host}/webpages/index.html"},
            cookies={"sysauth": self.sysauth}, timeout=REQUEST_TIMEOUT, verify=False,
        )


def decode_name(raw):
    if not raw:
        return "(unnamed)"
    try:
        return base64.b64decode(raw).decode("utf-8") or "(unnamed)"
    except Exception:
        return raw


def main():
    try:
        with open(CONFIG_PATH) as f:
            config = json.load(f)
    except FileNotFoundError:
        print(json.dumps({"error": "not_configured"}))
        return
    except Exception as e:
        print(json.dumps({"error": f"bad_config: {e}"}))
        return

    try:
        deco = Deco(config["host"], config.get("username", "admin"), config["password"])
        deco.login()
        mesh_nodes = deco.device_list()
        # "previous" is the mac of the node each hops its backhaul through —
        # for the master it's empty; for a slave it's usually the master,
        # but a weak signal can route it through another slave instead
        # (e.g. Living Room -> Kitchen -> Office rather than direct).
        names_by_mac = {n.get("mac", ""): n.get("nickname") or n.get("device_model", "Deco") for n in mesh_nodes}
        nodes = []
        for node in mesh_nodes:
            clients = deco.client_list(device_mac=node["mac"])
            via_mac = node.get("previous") or ""
            # dBm per band, only meaningful for a node that's actually
            # hopping its backhaul wirelessly through another node. Pick
            # whichever band is present/stronger (closer to 0 = stronger).
            strengths = node.get("signal_strength") or {}
            dbm_values = [v for v in strengths.values() if isinstance(v, (int, float))]
            nodes.append({
                "name": node.get("nickname") or node.get("device_model", "Deco"),
                "mac": node.get("mac", ""),
                "role": node.get("role", ""),
                "via": names_by_mac.get(via_mac, "") if via_mac else "",
                "via_dbm": max(dbm_values) if (via_mac and dbm_values) else None,
                "clients": [
                    {
                        "name": decode_name(c.get("name")),
                        "ip": c.get("ip", ""),
                        "mac": c.get("mac", ""),
                        "online": bool(c.get("online")),
                        # Deco reports these in Kbps.
                        "down_kbps": c.get("down_speed", 0),
                        "up_kbps": c.get("up_speed", 0),
                    }
                    for c in clients
                ],
            })
        deco.logout()
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        return

    print(json.dumps({"error": None, "nodes": nodes}))


if __name__ == "__main__":
    main()
