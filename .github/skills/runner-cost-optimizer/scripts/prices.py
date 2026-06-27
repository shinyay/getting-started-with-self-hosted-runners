#!/usr/bin/env python3
#
# prices.py - resolve ACI per-second pricing rates.
#
# With --live, fetches Linux Container Instances vCPU/memory rates for a region
# from the PUBLIC Azure Retail Prices API (no auth). On any failure, or without
# --live, it returns the documented static defaults. Emits JSON on stdout:
#   {"vcpu_second": <float>, "mem_gb_second": <float>, "source": "<source>"}
#
# Usage:
#   prices.py [--live] [--region eastus]
#             [--vcpu-rate R] [--mem-rate R]   # explicit overrides win
#
# All figures are estimates; ACI billing and meters change over time.

import argparse
import json
import sys
import urllib.parse
import urllib.request

DEF_VCPU_SECOND = 0.0000135
DEF_MEM_GB_SECOND = 0.0000015
API = "https://prices.azure.com/api/retail/prices"


def _to_second(unit_price, unit_of_measure):
    u = (unit_of_measure or "").lower()
    if "hour" in u:
        return unit_price / 3600.0
    if "second" in u:
        return unit_price
    # Unknown unit -> treat as hour (most common for duration meters).
    return unit_price / 3600.0


def fetch_live(region):
    flt = ("serviceName eq 'Container Instances' and armRegionName eq '%s' "
           "and priceType eq 'Consumption'" % region)
    url = "%s?$filter=%s" % (API, urllib.parse.quote(flt))
    vcpu = mem = None
    with urllib.request.urlopen(url, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    for item in data.get("Items", []):
        meter = (item.get("meterName") or "").lower()
        if "windows" in meter:
            continue
        price = item.get("unitPrice")
        uom = item.get("unitOfMeasure")
        if price is None:
            continue
        if vcpu is None and "vcpu" in meter:
            vcpu = _to_second(price, uom)
        elif mem is None and "memory" in meter:
            mem = _to_second(price, uom)
    if vcpu and mem:
        return vcpu, mem
    raise ValueError("could not parse vCPU/memory meters from retail prices")


def resolve(args):
    if args.vcpu_rate is not None and args.mem_rate is not None:
        return {"vcpu_second": args.vcpu_rate, "mem_gb_second": args.mem_rate,
                "source": "override"}
    if args.live:
        try:
            vcpu, mem = fetch_live(args.region)
            return {"vcpu_second": vcpu, "mem_gb_second": mem, "source": "live-retail-api"}
        except Exception as e:  # noqa: BLE001 - any failure falls back to static
            sys.stderr.write("WARN: live price fetch failed (%s); using static defaults\n" % e)
            return {"vcpu_second": DEF_VCPU_SECOND, "mem_gb_second": DEF_MEM_GB_SECOND,
                    "source": "static-fallback"}
    return {"vcpu_second": DEF_VCPU_SECOND, "mem_gb_second": DEF_MEM_GB_SECOND,
            "source": "static-default"}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Resolve ACI pricing rates")
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--region", default="eastus")
    ap.add_argument("--vcpu-rate", type=float)
    ap.add_argument("--mem-rate", type=float)
    args = ap.parse_args(argv)
    sys.stdout.write(json.dumps(resolve(args)) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
