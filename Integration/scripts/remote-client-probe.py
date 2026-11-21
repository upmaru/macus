#!/usr/bin/env python3
"""HTTPS probes the remote acceptance runner runs on its separate client (task 11.5).

Standard library only, so any Linux client with Python 3 can run it. It is
copied into the throwaway client and run there by remote-acceptance.py; it
never runs on the Macus host. Credentials are read from files, never from
arguments, and every result is one JSON document on stdout.

  probe.py tls URL CERTIFICATE
      TLS identity: a handshake verified against CERTIFICATE (the gateway
      certificate the client pins) with the URL's host checked, the peer
      certificate's SHA-256, a handshake that names another host (which must
      fail), and the anonymous `GET /1.0` the gateway answers itself.

  probe.py requests URL CERTIFICATE PLAN
      Runs PLAN, a JSON list of {"label", "kind": "http"|"mcp", ...}, and
      reports each status, MCP error flag and body by label.

  probe.py identity URL CERTIFICATE CLIENT_DIRECTORY
      `GET /1.0` presenting the client certificate and key in CLIENT_DIRECTORY
      (an INCUS_CONF): how the gateway sees that client (`auth`).

  probe.py fingerprint CERTIFICATE
      The SHA-256 of a PEM certificate (the client's own, for gateway trust).
"""
import hashlib
import http.client
import json
import socket
import ssl
import sys
import urllib.parse

PROTOCOL = "2026-07-28"


def target(url):
    parsed = urllib.parse.urlsplit(url)
    return parsed.hostname, parsed.port or 443


def context(certificate):
    pinned = ssl.create_default_context(cafile=certificate)
    pinned.minimum_version = ssl.TLSVersion.TLSv1_2
    return pinned


def fingerprint(path):
    with open(path) as handle:
        der = ssl.PEM_cert_to_DER_cert(handle.read())
    return hashlib.sha256(der).hexdigest()


def handshake(host, port, certificate, server_name):
    with socket.create_connection((host, port), timeout=15) as raw:
        with context(certificate).wrap_socket(raw, server_hostname=server_name) as tls:
            der = tls.getpeercert(binary_form=True)
            return {"version": tls.version(), "cipher": tls.cipher()[0],
                    "peer_sha256": hashlib.sha256(der).hexdigest()}


def request(host, port, certificate, method, path, token=None, body=None, headers=None,
            client=None):
    pinned = context(certificate)
    if client:
        pinned.load_cert_chain(f"{client}/client.crt", f"{client}/client.key")
    connection = http.client.HTTPSConnection(host, port, context=pinned, timeout=90)
    sent = dict(headers or {})
    if token is not None:
        sent["authorization"] = f"Bearer {token}"
    payload = None if body is None else json.dumps(body)
    if payload is not None:
        sent.setdefault("content-type", "application/json")
    try:
        connection.request(method, path, payload, sent)
        response = connection.getresponse()
        data = response.read()
    finally:
        connection.close()
    try:
        decoded = json.loads(data) if data else {}
    except ValueError:
        decoded = {"raw": data[:400].decode("utf-8", "replace")}
    return response.status, decoded


def tls(url, certificate):
    host, port = target(url)
    result = {"host": host, "port": port}
    try:
        result.update(handshake(host, port, certificate, host))
        result["connected"] = True
    except (OSError, ssl.SSLError) as error:
        result.update(connected=False, error=f"{type(error).__name__}: {error}")
        return result
    try:
        handshake(host, port, certificate, "not-the-gateway.invalid")
        result["other_name"] = "accepted"
    except ssl.SSLCertVerificationError as error:
        result["other_name"] = f"refused: {error.verify_message}"
    except (OSError, ssl.SSLError) as error:
        result["other_name"] = f"refused: {type(error).__name__}"
    status, body = request(host, port, certificate, "GET", "/1.0")
    metadata = body.get("metadata") or {}
    result["anonymous"] = {"status": status, "auth": metadata.get("auth"),
                           "auth_methods": metadata.get("auth_methods"),
                           "has_environment": bool(metadata.get("environment"))}
    return result


def identity(url, certificate, client):
    host, port = target(url)
    status, body = request(host, port, certificate, "GET", "/1.0", client=client)
    return {"status": status, "auth": (body.get("metadata") or {}).get("auth")}


def mcp(host, port, certificate, step, token):
    name, arguments = step["name"], step.get("arguments", {})
    body = {"jsonrpc": "2.0", "id": "remote-acceptance", "method": "tools/call", "params": {
        "name": name, "arguments": arguments, "_meta": {
            "io.modelcontextprotocol/protocolVersion": PROTOCOL,
            "io.modelcontextprotocol/clientCapabilities": {},
            "io.modelcontextprotocol/clientInfo": {"name": "macus-remote-acceptance",
                                                   "version": "1"}}}}
    headers = {"mcp-protocol-version": PROTOCOL, "mcp-method": "tools/call", "mcp-name": name,
               "accept": "application/json, text/event-stream"}
    status, decoded = request(host, port, certificate, "POST", "/mcp", token, body, headers)
    result = decoded.get("result") or {}
    return {"status": status, "is_error": bool(result.get("isError")),
            "body": result.get("structuredContent") or {}}


def requests(url, certificate, plan_path):
    host, port = target(url)
    with open(plan_path) as handle:
        plan = json.load(handle)
    results = {}
    for step in plan:
        token = None
        if step.get("token_file"):
            with open(step["token_file"]) as handle:
                token = handle.read().strip()
        try:
            if step["kind"] == "mcp":
                results[step["label"]] = mcp(host, port, certificate, step, token)
            else:
                status, body = request(host, port, certificate, step["method"], step["path"],
                                       token, step.get("body"))
                results[step["label"]] = {"status": status, "body": body}
        except (OSError, ssl.SSLError) as error:
            results[step["label"]] = {"status": None, "error": f"{type(error).__name__}: {error}"}
    return results


def main():
    command, arguments = sys.argv[1], sys.argv[2:]
    if command == "tls":
        result = tls(*arguments)
    elif command == "requests":
        result = requests(*arguments)
    elif command == "identity":
        result = identity(*arguments)
    elif command == "fingerprint":
        result = {"sha256": fingerprint(*arguments)}
    else:
        raise SystemExit(f"unknown probe {command}")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
