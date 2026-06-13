#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["fastapi", "uvicorn"]
# ///
"""
OVN REST API — Logical switch management endpoint.

Deployed on ovn11 by ovn-deploy.sh. Provides:
  POST   /api/bridge/             Create logical switch
  DELETE /api/bridge/{name}       Delete logical switch
  POST   /api/bridge/port/nic/xml Generate libvirt <interface> XML
  GET    /api/health              Health check
"""

import subprocess
import uuid

from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import JSONResponse
from pydantic import BaseModel

app = FastAPI(title="OVN API", version="1.0")
API_KEY = "ovn-api-key-2024"


class CreateBridgeRequest(BaseModel):
    name: str
    cidr: str
    gateway: str


class BuildInterfaceXmlRequest(BaseModel):
    bridgeName: str
    model: str = "virtio"
    mac: str


def check_key(x_api_key: str | None = Header(None)):
    if x_api_key != API_KEY:
        raise HTTPException(403, "Invalid API key")


def nbctl(*args):
    r = subprocess.run(
        ["ovn-nbctl"] + list(args),
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


@app.post("/api/bridge/")
async def create_bridge(req: CreateBridgeRequest, x_api_key: str | None = Header(None)):
    check_key(x_api_key)
    try:
        nbctl("ls-add", req.name)
        uuid_out = nbctl("--format=table", "list", "Logical_Switch", req.name)
        ls_uuid = ""
        for line in uuid_out.split("\n"):
            if "_uuid" in line:
                ls_uuid = line.split()[-1]
                break
        return JSONResponse({"code": 0, "msg": "ok", "data": {
            "app_bridge_name": f"ovn-{req.name}",
            "ovn_bridge_uuid": ls_uuid,
            "ovn_bridge_name": req.name,
        }})
    except Exception as e:
        return JSONResponse({"code": 1, "msg": str(e)})


@app.delete("/api/bridge/{name}")
async def delete_bridge(name: str, x_api_key: str | None = Header(None)):
    check_key(x_api_key)
    try:
        nbctl("ls-del", name)
        return JSONResponse({"code": 0, "msg": "ok", "data": {}})
    except Exception as e:
        return JSONResponse({"code": 1, "msg": str(e)})


@app.post("/api/bridge/port/nic/xml")
async def build_interface_xml(req: BuildInterfaceXmlRequest, x_api_key: str | None = Header(None)):
    check_key(x_api_key)
    port_name = f"lsp-{uuid.uuid4().hex[:8]}"
    xml = f"""\
    <interface type="bridge">
      <mac address="{req.mac}"/>
      <source bridge="{req.bridgeName}"/>
      <virtualport type="openvswitch"/>
      <model type="{req.model}"/>
    </interface>"""
    return JSONResponse({"code": 0, "msg": "ok", "data": {
        "xml": xml, "port_name": port_name,
        "mac": req.mac, "bridge_name": req.bridgeName,
    }})


@app.get("/api/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=18081)
