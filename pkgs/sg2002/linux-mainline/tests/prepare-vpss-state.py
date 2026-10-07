"""Compile the patched driver's real state/register code against a small host shim."""
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
fixture = pathlib.Path(sys.argv[2]).read_text()


def declaration(prefix):
    start = source.index(prefix)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if source[end:end + 1] == ";":
        end += 1
    return source[start:end]


parts = re.findall(r"^#define\s+(?:HW_FMT_\w+|VPSS_MIN_DIM|VPSS_MAX_DIM|IMG_\w+|SC_\w+|ODMA_\w+|TOP_\w+|CFG1_\w+|CSC_\w+)\s+[^\n]+",
                   source, re.MULTILINE)
for prefix in ["struct vpss_fmt {", "struct vpss_q_data {", "struct vpss_ctx {",
               "static const struct vpss_fmt vpss_out_fmts[]",
               "static const struct vpss_fmt vpss_cap_fmts[]",
               "static struct vpss_q_data *vpss_get_q_data",
               "static const struct vpss_fmt *vpss_find_fmt",
               "static int vpss_enum_fmt", "static void vpss_get_colorimetry",
               "static int vpss_g_fmt", "static int vpss_try_fmt",
               "static int vpss_s_fmt", "static void vpss_write_mask",
               "static void vpss_set_addr", "static void vpss_job_hw",
               "static int vpss_s_ctrl"]:
    parts.append(declaration(prefix))
print(fixture.replace("/* DRIVER_STATE */", "\n\n".join(parts)))
