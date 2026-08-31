import Foundation

/// The Python probe that talks to the DaVinci Resolve scripting API.
///
/// Written to a temp file at launch and run with `python3`. Emits one JSON object
/// per line on stdout, roughly every 2 seconds:
///
///     {"running": true, "apiOk": true, "page": "edit", "project": "X", "timeline": "V1", "timecode": "01:00:12:04", "rendering": false}
///     {"running": true, "apiOk": true, "page": null, "project": null}          // Project Manager
///     {"running": true, "apiOk": false, "reason": "scripting not responding"}  // Resolve up, API silent
///     {"running": false}                                                       // Resolve not running
///
/// It loops forever; on a fatal error it calls os._exit and lets Swift restart it.
let probeScriptSource = #"""
import sys, os, json, time, subprocess, glob

# Candidate locations for the scripting API + native library, most-likely first.
API_CANDIDATES = [
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting",
    os.path.expanduser("~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"),
]
_LIB_TAIL = "Contents/Libraries/Fusion/fusionscript.so"
LIB_CANDIDATES = [
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/" + _LIB_TAIL,
    "/Applications/DaVinci Resolve.app/" + _LIB_TAIL,
    "/Applications/DaVinci Resolve Studio.app/" + _LIB_TAIL,
    "/Applications/DaVinci Resolve/DaVinci Resolve Studio.app/" + _LIB_TAIL,
    # one directory level deep only — never a recursive walk of /Applications
] + glob.glob("/Applications/*/DaVinci Resolve*.app/" + _LIB_TAIL) \
  + glob.glob("/Applications/DaVinci Resolve*.app/" + _LIB_TAIL)

POLL = 2.0

def first_existing(paths):
    for p in paths:
        if p and os.path.exists(p):
            return p
    return None

def resolve_running():
    try:
        return subprocess.run(["pgrep", "-x", "Resolve"], capture_output=True).returncode == 0
    except Exception:
        return False

def emit(obj):
    try:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()
    except Exception:
        os._exit(0)

def norm(v):
    if v is None:
        return None
    v = str(v).strip()
    return v or None

def setup_env():
    api = first_existing(API_CANDIDATES)
    lib = first_existing(LIB_CANDIDATES)
    if not lib:
        return None, "DaVinci Resolve not found in /Applications"
    if api:
        os.environ["RESOLVE_SCRIPT_API"] = api
        modules = os.path.join(api, "Modules")
        os.environ["PYTHONPATH"] = os.environ.get("PYTHONPATH", "") + os.pathsep + modules
        sys.path.append(modules)
    os.environ["RESOLVE_SCRIPT_LIB"] = lib
    # The module lives next to the lib for some installs; make sure it's importable.
    try:
        import DaVinciResolveScript  # noqa
        return DaVinciResolveScript, None
    except Exception as e:
        return None, "scripting module not importable (%s)" % (str(e)[:120])

# Seconds to keep reporting the last-seen project after Resolve stops naming one,
# to bridge dialogs / background tasks that briefly null out page AND project.
STALE_PROJECT_WINDOW = 20.0

def main():
    dvr = None
    resolve = None
    import_reason = None
    api_strikes = 0
    transient_strikes = 0
    last_project = None
    last_timeline = None
    last_project_at = 0.0

    while True:
        if not resolve_running():
            resolve = None
            last_project = None
            emit({"running": False})
            time.sleep(POLL)
            continue

        if dvr is None:
            dvr, import_reason = setup_env()
            if dvr is None:
                emit({"running": True, "apiOk": False,
                      "reason": import_reason or "scripting unavailable"})
                time.sleep(POLL)
                continue

        try:
            if resolve is None:
                resolve = dvr.scriptapp("Resolve")
            if resolve is None:
                api_strikes += 1
                if api_strikes >= 3:
                    emit({"running": True, "apiOk": False,
                          "reason": "scripting not responding (check Preferences → System → General → External scripting)"})
                time.sleep(POLL)
                continue
            api_strikes = 0

            page = norm(resolve.GetCurrentPage())
            pm = resolve.GetProjectManager()
            proj = pm.GetCurrentProject() if pm else None
            name = norm(proj.GetName()) if proj else None
            tlname = None
            tc = None
            tlcount = 0
            rendering = False
            if proj is not None:
                try:
                    tlcount = int(proj.GetTimelineCount() or 0)
                except Exception:
                    tlcount = 0
                try:
                    tl = proj.GetCurrentTimeline()
                    if tl:
                        tlname = norm(tl.GetName())
                        try:
                            tc = norm(tl.GetCurrentTimecode())
                        except Exception:
                            tc = None
                except Exception:
                    tlname = None
                try:
                    rendering = bool(proj.IsRenderingInProgress())
                except Exception:
                    rendering = False

            now = time.time()
            busy = page is None

            # While loading a project or running a modal task (transcribe, sync, cache),
            # Resolve briefly swaps in its empty default project — same "Untitled Project"
            # name but zero timelines — or nulls the project entirely. Those aren't real
            # switches: a project you can actually edit in has at least one timeline.
            real = bool(name) and tlcount > 0
            if real:
                last_project = name
                last_timeline = tlname or last_timeline
                last_project_at = now
            elif last_project and (now - last_project_at) <= STALE_PROJECT_WINDOW:
                name = last_project
                tlname = tlname or last_timeline
            else:
                name = None

            emit({"running": True, "apiOk": True, "page": page,
                  "project": name, "timeline": tlname, "timecode": tc,
                  "rendering": rendering, "busy": busy})
            transient_strikes = 0
        except Exception as e:
            transient_strikes += 1
            if transient_strikes >= 3:
                resolve = None   # only rebuild the handle after repeated failures
            emit({"running": True, "apiOk": True, "transientError": str(e)[:200]})
        time.sleep(POLL)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    finally:
        os._exit(0)
"""#
