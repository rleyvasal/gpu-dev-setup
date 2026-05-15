# code calling
from IPython import get_ipython
from IPython.core.magic import register_cell_magic
from IPython.display import display, Image, HTML, Markdown
import base64
import sys

ip = get_ipython()

REMOTE_MODE = False
REMOTE_TOUCH = None
_REMOTE_PATCHED = False
_ORIGINAL_RUN_CELL = None


def _output_hook(msg):
    mt = msg["msg_type"]
    content = msg.get("content", {})

    if mt == "stream":
        out = sys.stderr if content.get("name") == "stderr" else sys.stdout
        print(content.get("text", ""), end="", file=out, flush=True)
        return

    if mt == "error":
        print("\n".join(content.get("traceback", [])))
        return

    if mt in ("display_data", "execute_result"):
        data = content.get("data", {})

        if "image/png" in data:
            display(Image(base64.b64decode(data["image/png"])))
        elif "image/jpeg" in data:
            display(Image(base64.b64decode(data["image/jpeg"])))
        elif "text/html" in data:
            display(HTML(data["text/html"]))
        elif "text/markdown" in data:
            display(Markdown(data["text/markdown"]))
        elif "text/plain" in data:
            print(data["text/plain"])


def _ensure_remote_client():
    if "kc" not in globals() or kc is None:
        raise RuntimeError("Remote kernel client 'kc' is not initialized.")


def _touch_remote_kernel():
    if REMOTE_TOUCH is not None:
        try:
            REMOTE_TOUCH()
        except Exception as exc:
            print(f"Warning: failed to touch remote kernel: {exc}", file=sys.stderr)


def _run_remote_cell(cell):
    _ensure_remote_client()
    _touch_remote_kernel()
    kc.execute_interactive(code=cell, output_hook=_output_hook)


def _patch_run_cell():
    global _REMOTE_PATCHED, _ORIGINAL_RUN_CELL

    if _REMOTE_PATCHED:
        return

    _ORIGINAL_RUN_CELL = ip.run_cell

    def patched_run_cell(raw_cell, *args, **kwargs):
        stripped = raw_cell.lstrip()

        if stripped.startswith("%%local") or stripped.startswith("%%remote"):
            return _ORIGINAL_RUN_CELL(raw_cell, *args, **kwargs)

        if REMOTE_MODE:
            _run_remote_cell(raw_cell)
            return None

        return _ORIGINAL_RUN_CELL(raw_cell, *args, **kwargs)

    ip.run_cell = patched_run_cell
    _REMOTE_PATCHED = True


def remote():
    global REMOTE_MODE
    _ensure_remote_client()
    _patch_run_cell()
    REMOTE_MODE = True
    print("Remote mode enabled. Normal cells will run on the remote kernel.")


def local():
    global REMOTE_MODE
    _patch_run_cell()
    REMOTE_MODE = False
    print("Local mode enabled. Normal cells will run in this notebook kernel.")


@register_cell_magic
def remote(line, cell):
    _run_remote_cell(cell)


@register_cell_magic
def local(line, cell):
    return _ORIGINAL_RUN_CELL(cell) if _ORIGINAL_RUN_CELL else ip.run_cell(cell)


_patch_run_cell()
print("Loaded remote/local mode helpers.")
print("Call remote() to switch normal cells to the remote kernel.")
print("Call local() to switch back to the local notebook kernel.")
print("Use %%remote or %%local to override per cell.")

