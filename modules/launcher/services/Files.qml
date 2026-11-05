pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.utils

Singleton {
    id: root

    property var results: []
    property string lastQuery: ""
    property bool searching: false

    function search(query: string): void {
        query = query.trim();

        if (query === root.lastQuery)
            return;

        // Deferred: this is called from within AppList's `values` binding,
        // which already reads `results`; writing to it synchronously here
        // (the empty-query case) would be a same-tick read/write loop
        Qt.callLater(() => root.applyQuery(query));
    }

    // Called when the launcher leaves file-search mode, so typing (or pasting)
    // the same query again runs a fresh search instead of reusing a stale or
    // failed one. Searches still in flight are dropped by the lastQuery checks.
    function reset(): void {
        if (root.lastQuery.length === 0 && !root.searching)
            return;
        root.lastQuery = "";
        root.searching = false;
        root.results = [];
    }

    function applyQuery(query: string): void {
        if (query === root.lastQuery)
            return;
        root.lastQuery = query;

        if (query.length === 0) {
            root.searching = false;
            root.results = [];
            return;
        }

        root.searching = true;
        debounce.pendingQuery = query;
        debounce.restart();
    }

    function extensionIcon(name: string): string {
        const dot = name.lastIndexOf(".");
        const ext = dot > 0 ? name.slice(dot + 1).toLowerCase() : "";

        if (ext === "pdf")
            return "picture_as_pdf";
        if (["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "avif", "heic"].includes(ext))
            return "image";
        if (["mp3", "wav", "flac", "ogg", "m4a", "opus", "aac"].includes(ext))
            return "music_note";
        if (["mp4", "mkv", "webm", "avi", "mov", "wmv", "flv"].includes(ext))
            return "movie";
        if (["zip", "tar", "gz", "xz", "7z", "rar", "bz2", "zst"].includes(ext))
            return "folder_zip";
        if (["js", "ts", "py", "qml", "c", "cpp", "h", "hpp", "rs", "go", "sh", "json", "yaml", "yml", "toml", "html", "css", "lua"].includes(ext))
            return "code";
        if (ext === "md" || ext === "txt")
            return "description";
        return "draft";
    }

    // Regex for an in-order fuzzy match: every query character, in the same
    // order, with anything in between (mypres -> m.*?y.*?p.*?r.*?e.*?s).
    // Characters are escaped so ( [ + etc. are matched literally.
    function fuzzyPattern(query: string): string {
        return Array.from(query).map(c => c.replace(/[\\.+*?()|[\]{}^$#&\-~]/g, "\\$&")).join(".*?");
    }

    // Two-pointer scan: positions of the query's characters in name, in order,
    // or null if they don't all appear in that order
    function fuzzyIndices(name: string, query: string): var {
        const idx = [];
        let qi = 0;
        for (let i = 0; i < name.length && qi < query.length; i++) {
            if (name[i] === query[qi]) {
                idx.push(i);
                qi++;
            }
        }
        return qi === query.length ? idx : null;
    }

    // Relevance score: exact match, then prefix match, then a match right
    // after a path/word boundary, then any other substring match, then an
    // in-order fuzzy match (tighter matches, with fewer skipped characters,
    // first)
    function fuzzyScore(name: string, query: string): int {
        if (name === query)
            return 1000;

        const idx = name.indexOf(query);
        if (idx === 0)
            return 800;
        if (idx > 0) {
            const boundary = /[._\-\s]/.test(name[idx - 1]);
            return (boundary ? 500 : 300) - idx;
        }

        const pos = root.fuzzyIndices(name, query);
        if (pos) {
            const skipped = pos[pos.length - 1] - pos[0] + 1 - query.length;
            return Math.max(1, 200 - skipped * 5 - pos[0]);
        }

        return 0;
    }

    // Caches, dependency folders and app data share generic names and drown
    // out real matches, so they're left out of the results entirely
    function isNoisy(path: string): bool {
        // Folders with these names, anywhere (and everything inside them)
        if (/\/(\.cache|\.git|node_modules|__pycache__|\.venv|venv|site-packages)(\/|$)/.test(path))
            return true;
        // App data under home: trash, Steam, VS Code extensions, Brave profile
        const rel = path.slice(Paths.home.length);
        return /^\/(\.local\/share\/Trash|\.local\/share\/Steam|\.vscode|\.config\/BraveSoftware)(\/|$)/.test(rel);
    }

    // Collapse long paths at directory boundaries (~/a/.../y/z) rather than
    // relying on character-level eliding, which cuts mid-word/mid-hash and
    // still reads as "the full path" even once it's visually truncated
    function shortenPath(path: string): string {
        const short = Paths.shortenHome(path);
        const parts = short.split("/");
        if (parts.length <= 4)
            return short;
        return `${parts[0]}/…/${parts.slice(-2).join("/")}`;
    }

    function buildResult(name: string, path: string, isDir: bool): var {
        const dir = path.slice(0, path.length - name.length - 1) || "/";

        return {
            icon: isDir ? "folder" : root.extensionIcon(name),
            name: name,
            desc: root.shortenPath(path),
            query: root.lastQuery,
            secondaryIcon: "folder_open",
            onSecondaryClicked: list => {
                Quickshell.execDetached(["xdg-open", dir]);
                list.screenState.launcher = false;
            },
            onClicked: list => {
                Quickshell.execDetached(["xdg-open", path]);
                list.screenState.launcher = false;
            }
        };
    }

    // Only ever apply results for the query that's currently displayed - a
    // slower, superseded search finishing late must not clobber newer results
    function finalize(query: string, paths: var): void {
        if (query !== root.lastQuery)
            return;

        // Keep results scoped to the user's own files
        const scoped = paths.filter(p => p === Paths.home || p.startsWith(`${Paths.home}/`));

        // Always follow up with a live fuzzy search, which also covers files
        // newer than plocate's index; both result sets are merged and ranked
        liveSearch.run(query, scoped);
    }

    function rank(query: string, paths: var, typeLines: var): void {
        const q = query.toLowerCase();

        const scored = paths.map((path, i) => {
            const parts = path.split("/");
            const name = parts[parts.length - 1] || path;
            const isDir = (typeLines[i] ?? "").startsWith("directory");
            const score = root.fuzzyScore(name.toLowerCase(), q);
            return { name, path, isDir, score, depth: parts.length };
        });

        scored.sort((a, b) => {
            if (a.score !== b.score)
                return b.score - a.score;
            if (a.depth !== b.depth)
                return a.depth - b.depth;
            return a.name.length - b.name.length;
        });

        root.searching = false;
        root.results = scored.slice(0, 40).map(f => root.buildResult(f.name, f.path, f.isDir));
    }

    Timer {
        id: debounce
        property string pendingQuery: ""
        interval: 250
        onTriggered: proc.run(debounce.pendingQuery)
    }

    Process {
        id: proc
        property var lines: []
        property string runningQuery: ""
        property string queuedQuery: ""

        function run(q: string): void {
            if (proc.running) {
                proc.queuedQuery = q;
                return;
            }

            proc.queuedQuery = "";
            proc.runningQuery = q;
            proc.lines = [];
            proc.command = ["plocate", "-i", "-b", "-l", "200", q];
            proc.running = true;
        }

        stdout: SplitParser {
            onRead: data => {
                if (!data)
                    return;
                proc.lines.push(data);
            }
        }

        onRunningChanged: {
            if (proc.running)
                return;

            // A newer query arrived while this one was still running - its
            // results are stale, drop them and go straight to the latest one
            if (proc.queuedQuery) {
                const next = proc.queuedQuery;
                proc.queuedQuery = "";
                proc.run(next);
                return;
            }

            root.finalize(proc.runningQuery, proc.lines);
        }
    }

    // Live, home-scoped fuzzy search with fd (plocate can only match
    // substrings quickly, and its index lags behind the real filesystem).
    // Its results are merged with plocate's, without duplicates.
    Process {
        id: liveSearch
        property var lines: []
        property var indexed: []
        property string runningQuery: ""

        function run(q: string, indexedPaths: var): void {
            liveSearch.runningQuery = q;
            liveSearch.indexed = indexedPaths;
            liveSearch.lines = [];
            // fd already skips hidden folders (.cache, .vscode, ...); skip the
            // other clutter folders too, so they don't use up the 200 results
            liveSearch.command = ["fd", "--max-results", "200", "-i", "--exclude", "node_modules", "--exclude", "__pycache__", "--exclude", "venv", "--exclude", "site-packages", "--", root.fuzzyPattern(q), Paths.home];
            liveSearch.running = true;
        }

        stdout: SplitParser {
            onRead: data => {
                if (!data)
                    return;
                liveSearch.lines.push(data);
            }
        }

        onRunningChanged: {
            if (liveSearch.running || liveSearch.runningQuery !== root.lastQuery)
                return;

            // fd prints folders with a trailing slash; drop it so the name
            // isn't empty and the same folder from both searches is deduplicated
            const seen = new Set();
            const merged = [];
            for (const raw of [...liveSearch.indexed, ...liveSearch.lines]) {
                const p = raw.length > 1 ? raw.replace(/\/+$/, "") : raw;
                // Caches, dependency folders and app data are just clutter
                if (!seen.has(p) && !root.isNoisy(p)) {
                    seen.add(p);
                    merged.push(p);
                }
            }

            if (merged.length === 0) {
                root.searching = false;
                root.results = [];
                return;
            }

            statProc.run(liveSearch.runningQuery, merged);
        }
    }

    // Batch-stat every candidate once so results can distinguish folders from
    // files and pick a sensible icon, instead of a single generic icon
    Process {
        id: statProc
        property var paths: []
        property var lines: []
        property string runningQuery: ""

        function run(q: string, candidatePaths: var): void {
            statProc.runningQuery = q;
            statProc.paths = candidatePaths;
            statProc.lines = [];
            statProc.command = ["stat", "-c", "%F", "--", ...candidatePaths];
            statProc.running = true;
        }

        stdout: SplitParser {
            onRead: data => {
                if (!data)
                    return;
                statProc.lines.push(data);
            }
        }

        onRunningChanged: {
            if (statProc.running || statProc.runningQuery !== root.lastQuery)
                return;

            root.rank(statProc.runningQuery, statProc.paths, statProc.lines);
        }
    }
}
