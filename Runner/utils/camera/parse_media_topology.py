#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
import sys
import re
import subprocess
import argparse

def fourcc_map(fmt):
    mapping = {
        "SRGGB10_1X10": "SRGGB10P",
        "RGGB8_1X8": "RGGB8",
        "BGGR10_1X10": "BGGR10P",
        "SRGGB8_1X8": "SRGGB8",
        "YUYV8_2X8": "YUYV",
        "UYVY8_2X8": "UYVY",
        # Add more as needed
    }
    return mapping.get(fmt, fmt)

def parse_entities(lines):
    entities = {}
    entity_pat = re.compile(r"^- entity (\d+): ([^\(]+)")
    device_pat = re.compile(r"device node name (.+)")
    type_pat = re.compile(r"type V4L2 subdev subtype (\w+)")
    pad_pat = re.compile(r"^\s*pad(\d+): (\w+)")
    link_pat = re.compile(r'-> "([^"]+)":(\d+) \[([^\]]*)\]')
    fmt_pat = re.compile(r"\[stream:(\d+) fmt:([^\s/]+)/(\d+)x(\d+)")
    fmt2_pat = re.compile(r"\[fmt:([^\s/]+)/(\d+)x(\d+)")
    sensor_pat = re.compile(r"type V4L2 subdev subtype Sensor flags")
    cur_entity = None
    cur_pad = None
    for line in lines:
        line = line.rstrip('\n')
        m = entity_pat.match(line)
        if m:
            idx, name = int(m.group(1)), m.group(2).strip()
            cur_entity = {
                'id': idx, 'name': name, 'pads': {}, 'devnode': None,
                'type': None, 'is_sensor': False
            }
            entities[idx] = cur_entity
            cur_pad = None
            continue
        if cur_entity is None:
            continue
        m = device_pat.search(line)
        if m:
            cur_entity['devnode'] = m.group(1).strip()
        m = type_pat.search(line)
        if m:
            cur_entity['type'] = m.group(1).strip()
        if sensor_pat.search(line):
            cur_entity['is_sensor'] = True
        m = pad_pat.match(line)
        if m:
            pad_idx, pad_type = int(m.group(1)), m.group(2)
            cur_entity['pads'][pad_idx] = {'type': pad_type, 'links': [], 'fmt': None, 'w': None, 'h': None}
            cur_pad = pad_idx
        m = link_pat.search(line)
        if m and cur_pad is not None:
            target, pad_idx, flags = m.group(1), int(m.group(2)), m.group(3)
            cur_entity['pads'][cur_pad]['links'].append({'target': target, 'pad': pad_idx, 'flags': flags})
        m = fmt_pat.search(line)
        if m and cur_pad is not None:
            _, fmt, w, h = m.groups()
            cur_entity['pads'][cur_pad].update({'fmt': fmt, 'w': w, 'h': h})
        m = fmt2_pat.search(line)
        if m and cur_pad is not None:
            fmt, w, h = m.groups()
            cur_entity['pads'][cur_pad].update({'fmt': fmt, 'w': w, 'h': h})
    return entities

def collect_supported_fourccs(video_ent, entities, fallback_fmt=None):
    fourccs = set()
    for pad in video_ent.get('pads', {}).values():
        if pad.get('fmt'):
            fourccs.add(pad['fmt'])
    if not fourccs:
        video_name = video_ent['name']
        for ent in entities.values():
            for pad in ent.get('pads', {}).values():
                for link in pad.get('links', []):
                    if link['target'] == video_name and pad.get('fmt'):
                        fourccs.add(pad['fmt'])
    if not fourccs and fallback_fmt:
        fourccs.add(fallback_fmt)
    return ','.join(sorted(fourccs)) if fourccs else 'None'

def collect_supported_modes(video_devnode):
    modes = set()
    if not video_devnode or not video_devnode.startswith('/dev/video'):
        return []
    try:
        output = subprocess.check_output(
            ["v4l2-ctl", "--device", video_devnode, "--list-formats-ext"],
            encoding="utf-8", stderr=subprocess.DEVNULL
        )
        current_fmt = None
        for line in output.splitlines():
            line = line.strip()
            if line.startswith('['):
                m = re.match(r"\[\d+\]:\s+'(\w+)'", line)
                if m:
                    current_fmt = m.group(1)
            elif "Size:" in line and current_fmt:
                matches = re.findall(r"(\d+)x(\d+)", line)
                for (w, h) in matches:
                    modes.add(f"{current_fmt}/{w}x{h}")
        return sorted(modes)
    except Exception:
        return []

def emit_media_ctl_v(entity, fmt, w, h):
    cmds = []
    for pad_num in [0, 1]:
        if pad_num in entity['pads']:
            pad = entity['pads'][pad_num]
            _fmt = fmt if fmt else pad.get('fmt', 'None')
            _w = w if w else pad.get('w', 'None')
            _h = h if h else pad.get('h', 'None')
            cmds.append(f'"{entity["name"]}":{pad_num}[fmt:{_fmt}/{_w}x{_h} field:none]')
    return cmds

def build_pipeline_cmds(sensor_ent, entities):
    results = []
    src_pad = sensor_ent['pads'].get(0)
    if not src_pad or not src_pad['links']:
        return results
    for lnk in src_pad['links']:
        csiphy_ent = next((e for e in entities.values() if e['name'] == lnk['target']), None)
        if not csiphy_ent: continue
        csid_ent = next((e for l in csiphy_ent['pads'].get(1, {}).get('links', []) if
                         (e := next((e for e in entities.values() if e['name'] == l['target']), None))), None)
        if not csid_ent: continue
        vfe_ent = next((e for l in csid_ent['pads'].get(1, {}).get('links', []) if
                        (e := next((e for e in entities.values() if e['name'] == l['target']), None))), None)
        if not vfe_ent: continue
        vid_ent = next((e for l in vfe_ent['pads'].get(1, {}).get('links', []) if
                        (e := next((e for e in entities.values() if e['name'] == l['target']), None))), None)
        if not vid_ent or not vid_ent.get('devnode'): continue

        video_node = vid_ent['devnode']
        if not video_supports_format(video_node):
            continue

        fmt = src_pad.get('fmt', 'None')
        short_fmt = fourcc_map(fmt)
        w = src_pad.get('w')
        h = src_pad.get('h')

        results.append({
            'SENSOR': sensor_ent['name'],
            'ENTITY': sensor_ent['id'],
            'CSIPHY': csiphy_ent['name'],
            'CSID': csid_ent['name'],
            'VFE': vfe_ent['name'],
            'VIDEO': video_node,
            'FMT': fmt,
            'W': w,
            'H': h,
            'SUBDEV': sensor_ent.get('devnode'),
            'SUPPORTED_FOURCCS': collect_supported_fourccs(vid_ent, entities, fmt),
            'SUPPORTED_MODE': collect_supported_modes(video_node),
            'MEDIA_CTL_V': (
                emit_media_ctl_v(sensor_ent, fmt, w, h) +
                emit_media_ctl_v(csiphy_ent, fmt, w, h) +
                emit_media_ctl_v(csid_ent, fmt, w, h) +
                emit_media_ctl_v(vfe_ent, fmt, w, h)
            ),
            'MEDIA_CTL_L': [
                f'"{sensor_ent["name"]}":0->"{csiphy_ent["name"]}":0[1]',
                f'"{csiphy_ent["name"]}":1->"{csid_ent["name"]}":0[1]',
                f'"{csid_ent["name"]}":1->"{vfe_ent["name"]}":0[1]',
                f'"{vfe_ent["name"]}":1->"{vid_ent["name"]}":0[1]',
            ],
            'YAVTA_DEV': video_node,
            'YAVTA_FMT': short_fmt,
            'YAVTA_W': w,
            'YAVTA_H': h,
            'YAVTA_CTRL_PRE': f"{sensor_ent.get('devnode')} 0x009f0903 0" if sensor_ent.get('devnode') else "",
            'YAVTA_CTRL': f"{sensor_ent.get('devnode')} 0x009f0903 9" if sensor_ent.get('devnode') else "",
            'YAVTA_CTRL_POST': f"{sensor_ent.get('devnode')} 0x009f0903 0" if sensor_ent.get('devnode') else ""
        })
    return results

def video_supports_format(video, fmt=None, w=None, h=None):
    if not video or video == "None":
        return False
    try:
        out = subprocess.check_output(["v4l2-ctl", "--device", video, "--list-formats-ext"],
                                      encoding="utf-8", stderr=subprocess.DEVNULL)
        if fmt:
            found_fmt = False
            for line in out.splitlines():
                if fmt in line:
                    found_fmt = True
                if found_fmt and w and h and f"{w}x{h}" in line:
                    return True
                if found_fmt and (not w or not h):
                    return True
            return False
        return True
    except Exception:
        return False

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("topo", help="media-ctl -p output text file")
    args = parser.parse_args()

    with open(args.topo) as f:
        lines = f.readlines()

    entities = parse_entities(lines)
    found = False
    for eid, ent in entities.items():
        if not ent.get('is_sensor'):
            continue
        pipelines = build_pipeline_cmds(ent, entities)
        for r in pipelines:
            found = True
            for k in ['SENSOR','ENTITY','CSIPHY','CSID','VFE','VIDEO','FMT','W','H','SUBDEV','SUPPORTED_FOURCCS']:
                print(f"{k}:{r[k]}")
            for mode in r['SUPPORTED_MODE']:
                print(f"SUPPORTED_MODE:{mode}")
            for v in r['MEDIA_CTL_V']:
                print(f"MEDIA_CTL_V:{v}")
            for l in r['MEDIA_CTL_L']:
                print(f"MEDIA_CTL_L:{l}")
            if r['YAVTA_CTRL_PRE']: print(f"YAVTA_CTRL_PRE:{r['YAVTA_CTRL_PRE']}")
            if r['YAVTA_CTRL']: print(f"YAVTA_CTRL:{r['YAVTA_CTRL']}")
            if r['YAVTA_CTRL_POST']: print(f"YAVTA_CTRL_POST:{r['YAVTA_CTRL_POST']}")
            print(f"YAVTA_DEV:{r['YAVTA_DEV']}")
            print(f"YAVTA_FMT:{r['YAVTA_FMT']}")
            print(f"YAVTA_W:{r['YAVTA_W']}")
            print(f"YAVTA_H:{r['YAVTA_H']}")
            print("--")
    if not found:
        print("SKIP: No valid camera pipelines found in topology.")
        sys.exit(2)

if __name__ == "__main__":
    main()
