#!/usr/bin/env python3
"""CAD(DXF/DWG) → 도면별 표제란 메타 추출 → JSON.

MES 의 CAD 견적 BOM 애드온이 호출한다(System.cmd). 업로드된 CAD 파일 경로들을 인자로 받아
각 도곽(CMK_a3 등)의 표제란에서 도번·도면명·발주처·모델·작성자·날짜를 추출하고,
원본 파일명에서 작업분류(가공/레이저/부품/승인…)를 추론해 JSON 한 줄로 출력한다.

추출 로직은 ara_big_cad 파이프라인의 meta.py(표제란 셀 상대좌표 기반)를 그대로 옮긴 것.
DWG 는 ODA File Converter 가 설치돼 있으면 DXF 로 변환 후 처리한다.
출력: {"rows":[{dwg_no,title,client,model,drawer,date,source,work_category}], "files":[...], "errors":[...]}
"""
import sys
import os
import json
import re
import subprocess
import tempfile
import shutil
import logging

logging.disable(logging.CRITICAL)

import ezdxf
from ezdxf import bbox

CP = {'1': 'cp932', '2': 'cp950', '3': 'cp949', '4': 'cp936', '5': 'cp949'}


def dec(s):
    s = re.sub(
        r'\\M\+([1-5])([0-9A-Fa-f]{4})',
        lambda m: bytes([int(m.group(2)[:2], 16), int(m.group(2)[2:], 16)]).decode(
            CP.get(m.group(1), 'cp949'), 'replace'),
        s)
    s = re.sub(r'%%[uUdDcCpP]', '', s)
    s = s.replace('\\P', ' ')
    s = re.sub(r'\\[A-Za-z][^;]*;', '', s)
    return ' '.join(s.split()).strip()


def _cell(items, rx0, rx1, ry0, ry1, skip=("-", "", "–")):
    c = [(rx, ry, t) for rx, ry, t in items
         if rx0 <= rx <= rx1 and ry0 <= ry <= ry1 and t and t not in skip]
    c.sort(key=lambda r: (-r[1], r[0]))
    return c[0][2] if c else ""


def frame_meta(items):
    """CMK_a3 표제란 셀(상대좌표) → 메타. meta.py 와 동일."""
    title = _cell(items, 0.66, 0.88, 0.13, 0.18)
    dno = _cell(items, 0.74, 0.90, 0.045, 0.092)
    if re.match(r"^'?\d{2}[.\-]\d", dno):
        dno = ""
    client = _cell(items, 0.66, 0.92, 0.105, 0.135)
    model = _cell(items, 0.66, 0.86, 0.085, 0.11)
    drawer = _cell(items, 0.60, 0.74, 0.05, 0.09)
    date = _cell(items, 0.60, 0.78, 0.02, 0.055)
    return dict(dwg_no=dno, title=title, client=client, model=model, drawer=drawer, date=date)


FRAME_BLOCKS = ("CMK_a3", "SF00", "A3", "format1")


def extract_one(path):
    doc = ezdxf.readfile(path)
    msp = doc.modelspace()
    names = {e.dxf.name for e in msp if e.dxftype() == "INSERT"}
    fb = next((c for c in FRAME_BLOCKS if c in names), None)
    if not fb:
        return [], None, 0
    frs = [e for e in msp if e.dxftype() == "INSERT" and e.dxf.name == fb]
    txt = []
    for e in msp:
        if e.dxftype() in ("TEXT", "MTEXT"):
            try:
                c = e.dxf.insert
            except Exception:
                continue
            t = dec(e.dxf.text if e.dxftype() == "TEXT" else e.text)
            if t:
                txt.append((c.x, c.y, t))
    rows = []
    for fr in frs:
        bb = bbox.extents([fr], fast=True)
        if not bb.has_data:
            continue
        x0, y0, w, h = bb.extmin.x, bb.extmin.y, bb.size.x, bb.size.y
        if w <= 0 or h <= 0:
            continue
        ins = [((x - x0) / w, (y - y0) / h, t) for x, y, t in txt
               if x0 <= x <= x0 + w and y0 <= y <= y0 + h]
        rows.append(frame_meta(ins))
    return rows, fb, len(frs)


# 원본 파일명 → 작업분류(과거 명명 관행). 키워드 우선순위 순.
WORK_PAT = [("레이저", "레이저"), ("laser", "레이저"), ("커팅", "커팅"), ("cutting", "커팅"),
            ("절곡", "절곡"), ("용접", "용접"), ("가공", "가공"), ("부품", "부품"), ("승인", "승인")]


def work_category(src):
    s = src.lower()
    for kw, cat in WORK_PAT:
        if kw.lower() in s:
            return cat
    return ""


def to_dxf_if_needed(path):
    """DWG 면 ODA File Converter 로 DXF 변환. (DXF 는 그대로) 반환: (dxf_path|None, tmpdir|None)"""
    if path.lower().endswith(".dxf"):
        return path, None
    oda = "/Applications/ODAFileConverter.app/Contents/MacOS/ODAFileConverter"
    if path.lower().endswith(".dwg") and os.path.exists(oda):
        ind, outd = tempfile.mkdtemp(), tempfile.mkdtemp()
        shutil.copy(path, ind)
        subprocess.run([oda, ind, outd, "ACAD2018", "DXF", "0", "1", "*.DWG"],
                       timeout=180, capture_output=True)
        for f in os.listdir(outd):
            if f.lower().endswith(".dxf"):
                return os.path.join(outd, f), outd
    return None, None


def main():
    out = {"rows": [], "files": [], "errors": []}
    for p in sys.argv[1:]:
        src = os.path.basename(p)
        cat = work_category(src)
        try:
            dxf, _tmp = to_dxf_if_needed(p)
            if not dxf:
                out["errors"].append({"file": src, "error": "DXF 변환 불가(.dwg 는 ODA File Converter 필요)"})
                continue
            rows, fb, n = extract_one(dxf)
            for r in rows:
                r["source"] = src
                r["work_category"] = cat
                out["rows"].append(r)
            out["files"].append({"file": src, "frames": n, "frame_block": fb, "parts": len(rows)})
        except Exception as e:
            out["errors"].append({"file": src, "error": str(e)})
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
