"""Write a minimal one-page PDF with a fake grant application (no third-party libraries)."""
import sys

lines = [
    "SAMPLE APPLICATION - TEST DATA ONLY",
    "Title: Low-cost sensors for river ice monitoring",
    "Aims: (1) build a sensor network on three rivers;",
    "(2) predict ice jams 48 hours ahead; (3) share open data.",
    "Methods: field deployment, machine learning, community partners.",
]
text = "BT /F1 12 Tf 72 720 Td 16 TL " + " ".join(
    "(%s) Tj T*" % l.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") for l in lines
) + " ET"
objs = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
    "/Resources << /Font << /F1 5 0 R >> >> >>",
    "<< /Length %d >>\nstream\n%s\nendstream" % (len(text), text),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
out = b"%PDF-1.4\n"
offsets = []
for i, o in enumerate(objs, 1):
    offsets.append(len(out))
    out += ("%d 0 obj\n%s\nendobj\n" % (i, o)).encode()
xref = len(out)
out += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode()
out += "".join("%010d 00000 n \n" % off for off in offsets).encode()
out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)).encode()
open(sys.argv[1], "wb").write(out)
