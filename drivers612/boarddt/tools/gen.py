#!/usr/bin/env python3
"""
gen.py: translate the phone's stock dtbo entries (Samsung 5.4 board description, compiled with
-@) into a labelled dts SOURCE tree for the Qualcomm 6.12 base.

  common   = every node/property that is identical in all hardware-revision entries
  per-rev  = the remainder of each entry
  split    = one include per subsystem; nodes of subsystems owned by other agents and
             everything whose target label does not exist in the 6.12 base go to
             placeholders/ (copied verbatim, TODO-binding)

Phandle cells are turned back into &label references (from __fixups__, __local_fixups__ and
__symbols__), so nothing depends on numeric phandles.

usage: gen.py <base.dtb> <outdir> <rev-name>=<entry.dtb> ...
"""
import os, re, struct, sys
from collections import OrderedDict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fdt

SMD = "samsung_mobile_device"
AGENTS = ["display", "touch", "power", "audio", "camera", "conn", "secure", "gpu-video"]
OWN = ["memory", "pinctrl", "regulators", "pmic", "thermal", "buses", "storage", "usb",
       "sensors", "nfc", "input", "sec-platform", "rf", "misc"]

# ordered rules: (subsystem, regex on "target/child [compatibles of the subtree]")
RULES = [
    ("memory", r"^(reserved_memory|\w+_mem|secure_carveout_heap|msm_imem)/"),
    ("audio", r"^(lpi_tlmm|bolero|\w+_swr_gpios|yupik_snd|q6core|va_cdc_dma\w*|dai_\w+|adsp_loader|fsa4480)/"),
    ("pinctrl", r"^tlmm/"),
    ("regulators", r"^(pm\w+_[ls]\d+|apps_rsc|[LS]\d+[A-Z])/"),
    ("thermal", r"^thermal_zones/"),
    ("display", r"^mdss_mdp/|/(\S*(dsi|panel|sde|mdss)\S*)( |$)|ss_dsi|samsung,mdss"),
    ("camera", r"^cam_cci\d/|/\S*(cam|ois|eeprom|actuator|s2mpb03|pm8008|fled|flash)\S*( |$)|qcom,cam|leds-sm5714"),
    ("touch", r"/\S*(touch|novatek|tsp|stm_ts|sec_ts|ss_touch)\S*( |$)|stm,|sec_input"),
    ("pmic", r"^(spmi_bus|spmi_debug_bus|spmi_glink_debug)/"),
    ("secure", r"/\S*(et7xx|etspi|finger|qseecom|ese|smcinvoke|tzlog|tz_log|mst|hdm|tima|kaslr|knox|uh)\S*( |$)|etspi|qbt"),
    ("nfc", r"/\S*(nfc|nq@)\S*( |$)"),
    ("power", r"^battery_charger/|/\S*(battery|charger|sm5714|pca9468|usbpd|fuelgauge|muic|ccic|vbus|pdic|typec|if_pmic|otg|wireless|cable)\S*( |$)"),
    ("conn", r"^pcie\d(_msi)?/|/\S*(wlan|bluetooth|bt_|wifi|icnss|cnss|wcn)\S*( |$)"),
    ("gpu-video", r"/\S*(kgsl|gpu|vidc|video)\S*( |$)"),
    ("audio", r"/\S*(wsa|cdc|tas25|snd|sound|audio|swr|dmic|wcd|_clk|lpass|apr|ear|spk|mic)\S*( |$)|qcom,audio|tas256"),
    ("sensors", r"/\S*(adsp_factory|sensor|grip|sx93|hall|ssc|shub|flip|prox|light)\S*( |$)|samsung,adsp|sx9360"),
    ("storage", r"^(ufs\w+|sdhc_\d)/"),
    ("usb", r"^usb\d/|/\S*(usb|dwc3|eud)\S*( |$)"),
    ("buses", r"^qupv3_\w+/"),
    ("rf", r"/\S*(ant|rf_|sar|sim|tray|cp_|modem)\S*( |$)"),
    ("input", r"/\S*(key|vib|motor|haptic)\S*( |$)"),
    ("sec-platform", r"^/[ /]|/\S*(sec_|sec-|samsung|abc|debug|reboot|thermistor|argos|boot_stat|param)\S*( |$)"),
]

def classify(tkey, child, compats):
    text = "%s/%s %s" % (tkey, child or "", " ".join(compats))
    for sub, rx in RULES:
        if re.search(rx, text):
            return sub
    return "misc"

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

class Variant:
    """One dtbo entry, as {(tkey, relpath): {'labels', 'props'}} with symbolic values."""
    def __init__(self, path):
        self.root = fdt.load(path)
        r = self.root
        self.rootprops = OrderedDict((k, v) for k, v in r.props.items())
        self.ext = {}      # (nodepath, prop) -> {offset: label}
        for label, v in r.children["__fixups__"].props.items():
            for s in fdt.strings(v):
                p, pr, off = s.rsplit(":", 2)
                self.ext.setdefault((p, pr), {})[int(off)] = label
        self.loc = {}      # (nodepath, prop) -> [offsets]
        lf = r.children.get("__local_fixups__")
        if lf:
            for n in lf.walk():
                np = n.path()[len("/__local_fixups__"):] or "/"
                for pr, v in n.props.items():
                    self.loc[(np, pr)] = list(struct.unpack(">%dI" % (len(v) // 4), v))
        self.labels = {}   # nodepath -> [labels]
        for label, p in fdt.symbols(r).items():
            self.labels.setdefault(p, []).append(label)
        self.by_phandle = {}
        for n in r.walk():
            ph = n.props.get("phandle")
            if ph and len(ph) == 4:
                self.by_phandle[struct.unpack(">I", ph)[0]] = n.path()
        self.synth = 0
        self.nodes = OrderedDict()
        self.ext_used = set()
        for name, frag in r.children.items():
            ov = frag.children.get("__overlay__")
            if ov is None:
                continue
            fp = "/" + name
            if "target-path" in frag.props:
                tkey = frag.props["target-path"].rstrip(b"\0").decode()
            else:
                tkey = self.ext[(fp, "target")][0]
            base = ov.path()
            for n in ov.walk():
                rel = tuple(x for x in n.path()[len(base):].split("/") if x)
                ent = self.nodes.setdefault((tkey, rel), {"labels": [], "props": OrderedDict()})
                for l in self.labels.get(n.path(), []):
                    if l not in ent["labels"]:
                        ent["labels"].append(l)
                for pr, v in n.props.items():
                    if pr in ("phandle", "linux,phandle"):
                        continue
                    ent["props"][pr] = self.value(n.path(), pr, v)

    def label_of_phandle(self, ph):
        p = self.by_phandle.get(ph)
        if p is None:
            return None
        ls = self.labels.get(p)
        if not ls:
            self.synth += 1
            ls = ["a52_ref_%s" % re.sub(r"\W", "_", p.rsplit("/", 1)[1])]
            self.labels[p] = ls
        return ls[0]

    def value(self, npath, pr, v):
        ext = self.ext.get((npath, pr), {})
        loc = set(self.loc.get((npath, pr), []))
        if not v:
            return ""
        if not ext and not loc and fdt.is_strings(v):
            return ", ".join('"%s"' % esc(s) for s in fdt.strings(v))
        if len(v) % 4 == 0:
            out = []
            for i in range(0, len(v), 4):
                c = struct.unpack_from(">I", v, i)[0]
                if i in ext:
                    out.append("&" + ext[i]); self.ext_used.add(ext[i])
                elif i in loc:
                    l = self.label_of_phandle(c)
                    out.append("&" + l if l else "0x%x /* dangling local phandle */" % c)
                else:
                    out.append("0x%x" % c)
            return "<" + " ".join(out) + ">"
        return "[" + " ".join("%02x" % b for b in v) + "]"

def emit_tree(out, items, indent):
    """items: list of (relpath tuple, labels, props) sharing one anchor; prints nested nodes."""
    tree = OrderedDict()   # name -> [labels, props, subtree]
    rootprops = OrderedDict()
    for rel, labels, props in items:
        if not rel:
            rootprops.update(props); continue
        cur = tree
        for i, part in enumerate(rel):
            ent = cur.setdefault(part, [[], OrderedDict(), OrderedDict()])
            if i == len(rel) - 1:
                for l in labels:
                    if l not in ent[0]:
                        ent[0].append(l)
                ent[1].update(props)
            cur = ent[2]
    def pr(props, ind):
        for k, v in props.items():
            out.append("%s%s%s;" % (ind, k, " = " + v if v else ""))
    def rec(t, ind):
        for name, (labels, props, sub) in t.items():
            out.append("")
            out.append("%s%s%s {" % (ind, "".join(l + ": " for l in labels), name))
            pr(props, ind + "\t")
            rec(sub, ind + "\t")
            out.append("%s};" % ind)
    pr(rootprops, indent)
    rec(tree, indent)

def tref(tkey):
    return "&{%s}" % tkey if tkey.startswith("/") else "&" + tkey

def main():
    basef, outdir = sys.argv[1], sys.argv[2]
    variants = OrderedDict()
    skip = set()
    args = sys.argv[3:]
    if args and args[0].startswith("--skip-labels="):
        # labels that an integrated agent fragment defines itself: drop our copy of those nodes
        skip = set(open(args[0].split("=", 1)[1]).read().split())
        args = args[1:]
    for a in args:
        name, path = a.split("=", 1)
        variants[name] = Variant(path)
    base_syms = fdt.symbols(fdt.load(basef))
    if skip:
        for v in variants.values():
            dead = [k for k, e in v.nodes.items() if set(e["labels"]) & skip]
            for k in list(v.nodes):
                if any(k[0] == d[0] and k[1][:len(d[1])] == d[1] for d in dead):
                    del v.nodes[k]
    ref = list(variants.values())[-1]          # newest revision = reference ordering
    vs = list(variants.values())

    # ---- common / per-revision split
    common_nodes = [k for k in ref.nodes if all(k in v.nodes for v in vs)]
    common = OrderedDict()
    for k in common_nodes:
        props = OrderedDict((p, val) for p, val in ref.nodes[k]["props"].items()
                            if all(v.nodes[k]["props"].get(p) == val for v in vs))
        labels = [l for l in ref.nodes[k]["labels"] if all(l in v.nodes[k]["labels"] for v in vs)]
        common[k] = {"labels": labels, "props": props}
    common_labels = {l: k for k, e in common.items() for l in e["labels"]}

    # ---- labels the 6.12 base does not have (fragment targets and plain references)
    used = set()
    for v in vs:
        used |= v.ext_used | {k[0] for k in v.nodes if not k[0].startswith("/")}
    missing = sorted(l for l in used if l not in base_syms and l not in skip)
    targets = {k[0] for v in vs for k in v.nodes}

    # ---- classify units (target, first child)
    def unit_compats(v, tkey, child):
        cs = []
        for (t, rel), e in v.nodes.items():
            if t == tkey and ((child is None and not rel) or (rel and rel[0] == child)):
                c = e["props"].get("compatible")
                if c and c.startswith('"'):
                    cs += re.findall(r'"([^"]*)"', c)
        return cs
    unit_sub = {}
    def sub_of(v, k):
        if k[0] == "/" and len(k[1]) >= 2 and k[1][0] == SMD:
            u = (SMD, k[1][1])
            if u not in unit_sub:
                cs = [c for (t, rel), e in v.nodes.items() if t == "/" and rel[:2] == k[1][:2]
                      for c in re.findall(r'"([^"]*)"', e["props"].get("compatible", ""))]
                unit_sub[u] = classify(SMD, u[1], cs)
            return unit_sub[u]
        u = (k[0], k[1][0] if k[1] else None)
        if u not in unit_sub:
            unit_sub[u] = classify(u[0], u[1], unit_compats(v, *u))
        return unit_sub[u]
    stub_sub = {}
    for l in missing:
        stub_sub[l] = classify(l, None, []) if l in targets else None
    # a missing label that is only referenced: give it to the subsystem of its first user
    for v in vs:
        for k, e in v.nodes.items():
            for val in e["props"].values():
                for l in re.findall(r"&(\w+)", val):
                    if l in stub_sub and stub_sub[l] is None:
                        stub_sub[l] = sub_of(v, k)
    for l in missing:
        if stub_sub[l] in (None, "misc", "memory", "pinctrl", "sec-platform", "thermal"):
            stub_sub[l] = {"secure_carveout_heap": "secure", "msm_imem": "sec-platform"}.get(
                l, "audio" if re.search(r"lpi|pcm|voi|afe|lsm|rout|compr|loopback|hostless|lpass|codec", l)
                else "display" if re.search(r"mdss|sde", l) else stub_sub[l] or "misc")

    files = OrderedDict((s, []) for s in OWN + AGENTS)
    # stubs first
    stubs = OrderedDict()
    for l in missing:
        stubs.setdefault(stub_sub[l], []).append(l)
    labelfiles = OrderedDict()
    for sub, ls in stubs.items():
        o = labelfiles.setdefault(sub, [])
        o.append("/*\n * Labels of the 5.4 base that the 6.12 base does not have. Placeholders under\n"
                 " * /soc/a52sxq-todo-%s (no compatible: nothing binds, children are not populated)\n"
                 " * so that every reference of the phone's tree resolves. TODO-binding: replace by the\n"
                 " * real 6.12 node of the owning driver and delete the placeholder.\n */" % sub)
        o.append("&soc {\n\ta52sxq_todo_%s: a52sxq-todo-%s {\n\t\ta52sxq,todo-binding;" % (sub.replace("-", "_"), sub))
        for l in ls:
            o.append("\t\t%s: %s {\n\t\t\ta52sxq,placeholder-for = \"%s\";\n\t\t};" % (l, l.replace("_", "-"), l))
        o.append("\t};\n};\n")

    # common content, grouped by (file, target)
    groups = OrderedDict()
    for k, e in common.items():
        if k[0] == "/" and len(k[1]) >= 2 and k[1][0] == SMD:
            groups.setdefault((sub_of(ref, k), common[("/", (SMD,))]["labels"][0]), []).append((k[1][1:], e["labels"], e["props"]))
        else:
            groups.setdefault((sub_of(ref, k), k[0]), []).append((k[1], e["labels"], e["props"]))
    for (sub, tkey), items in groups.items():
        if all(not rel and not props for rel, _, props in items):
            continue
        o = files[sub]
        note = "" if tkey.startswith("/") or tkey in base_syms or tkey in common_labels else "\t/* TODO-binding: label not in the 6.12 base, placeholder */"
        o.append("%s {%s" % (tref(tkey), note))
        emit_tree(o, items, "\t")
        o.append("};\n")

    os.makedirs(os.path.join(outdir, "placeholders"), exist_ok=True)
    hdr = ("// SPDX-License-Identifier: GPL-2.0\n/*\n * a52sxq board description for the Qualcomm 6.12 yupik base: %s\n"
           " * GENERATED by tools/gen.py from the phone's stock dtbo (5.4 bindings, values verbatim).\n"
           " * Do not edit: hand-written 6.12 changes live in a52sxq-bsp612-fixups.dtsi.\n */\n\n")
    index = []
    for sub, o in labelfiles.items():
        rel = "placeholders/a52sxq-%s-labels.dtsi" % sub
        with open(os.path.join(outdir, rel), "w") as f:
            f.write(hdr % ("placeholder labels for '%s'" % sub))
            f.write("\n".join(o) + "\n")
        index.append((sub + ":labels", rel))
    for sub, o in files.items():
        if not o:
            continue
        rel = ("placeholders/a52sxq-%s-placeholder.dtsi" if sub in AGENTS else "a52sxq-%s.dtsi") % sub
        with open(os.path.join(outdir, rel), "w") as f:
            f.write(hdr % (sub + (" (owned by agent '%s': TODO-binding placeholder)" % sub if sub in AGENTS else "")))
            f.write("\n".join(o) + "\n")
        index.append((sub, rel))

    # per-revision remainders
    for name, v in variants.items():
        o = []
        by_anchor = OrderedDict()
        for k, e in v.nodes.items():
            if k in common:
                props = OrderedDict((p, val) for p, val in e["props"].items() if common[k]["props"].get(p) != val)
                labels = [l for l in e["labels"] if l not in common[k]["labels"]]
                if not props and not labels:
                    continue
            else:
                props, labels = e["props"], e["labels"]
            # anchor: nearest ancestor-or-self that is in common and carries a label
            anchor, relp = None, k[1]
            for i in range(len(k[1]), 0, -1):
                ck = (k[0], k[1][:i])
                if ck in common and common[ck]["labels"]:
                    anchor, relp = common[ck]["labels"][0], k[1][i:]
                    break
            by_anchor.setdefault(anchor or k[0], []).append((relp, labels, props))
        for anchor, items in by_anchor.items():
            o.append("%s {" % tref(anchor))
            emit_tree(o, items, "\t")
            o.append("};\n")
        with open(os.path.join(outdir, "a52sxq-%s.dtsi" % name), "w") as f:
            f.write(hdr % ("what only hardware-revision entry %s has" % name))
            f.write("\n".join(o) + "\n" if o else "/* nothing: this entry equals the common part */\n")
        # root (selection) properties, verbatim
        with open(os.path.join(outdir, "out", "root-%s.txt" % name), "w") as f:
            for p, val in v.rootprops.items():
                f.write("\t%s = %s;\n" % (p, v.value("/", p, val)))

    with open(os.path.join(outdir, "a52sxq-common.dtsi"), "w") as f:
        f.write(hdr % "common part (all hardware revisions)")
        f.write("/* own subsystems (sec-platform first: it defines &samsung_mobile_device) */\n")
        own = [(s_, r_) for s_, r_ in index if s_ not in AGENTS and not s_.endswith(":labels")]
        own.sort(key=lambda x: x[0] != "sec-platform")
        for sub, rel in own:
            f.write('/include/ "%s"\n' % rel)
        f.write("\n/* subsystems owned by other drivers612 agents: see a52sxq-agents.dtsi (written by check-dt.sh) */\n")
    with open(os.path.join(outdir, "out", "gen-index.txt"), "w") as f:
        for sub, rel in index:
            f.write("%s\t%s\n" % (sub, rel))
        f.write("# missing labels: %s\n" % " ".join("%s(%s)" % (l, stub_sub[l]) for l in missing))
        f.write("# units: " + " ".join("%s/%s=%s" % (u[0], u[1], s) for u, s in unit_sub.items()) + "\n")
    with open(os.path.join(outdir, "out", "nodes-compat.tsv"), "w") as f:
        for k, e in ref.nodes.items():
            c = e["props"].get("compatible", "")
            if c.startswith('"'):
                f.write("%s\t%s/%s\t%s\t%s\n" % (sub_of(ref, k), k[0], "/".join(k[1]), "|".join(re.findall(r'"([^"]*)"', c)),
                        e["props"].get("status", "").strip('"')))
    with open(os.path.join(outdir, "out", "units.tsv"), "w") as f:
        for k, e in ref.nodes.items():
            if not k[1] and e["props"]:
                f.write("%s\t%s\t\t%s\n" % (sub_of(ref, k), k[0], " ".join(e["props"])))
            elif len(k[1]) == 1:
                f.write("%s\t%s\t%s\t\n" % (sub_of(ref, k), k[0], k[1][0]))
            elif len(k[1]) == 2 and k[0] == "/" and k[1][0] == SMD:
                f.write("%s\t%s\t%s\t\n" % (sub_of(ref, k), k[0], "/".join(k[1])))
    print("gen: %d common nodes, %d missing labels, files: %s" % (len(common), len(missing), " ".join(r for _, r in index)))
    for name, v in variants.items():
        extra = sum(1 for k in v.nodes if k not in common)
        print("  %s: %d nodes, %d not in common, %d synthesized labels" % (name, len(v.nodes), extra, v.synth))

main()
