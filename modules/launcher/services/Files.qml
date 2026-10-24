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

    // Simple relevance score: exact match, then prefix match, then a match
    // right after a path/word boundary, then any other substring match
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

        return 0;
    }

    // Generated/cache junk (colour scheme caches, git internals, dependency
    // trees, ...) tends to share generic names and drown out real matches
    function isNoisy(path: string): bool {
        return /\/\.cache\/|\/\.git\/|\/node_modules\/|\/\.local\/share\/Trash\//.test(path);
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

        if (scoped.length === 0) {
            root.searching = false;
            root.results = [];
            liveFallback.run(query);
            return;
        }

        statProc.run(query, scoped);
    }

    function rank(query: string, paths: var, typeLines: var): void {
        const q = query.toLowerCase();

        const scored = paths.map((path, i) => {
            const parts = path.split("/");
            const name = parts[parts.length - 1] || path;
            const isDir = (typeLines[i] ?? "").startsWith("directory");
            const score = root.fuzzyScore(name.toLowerCase(), q) - (root.isNoisy(path) ? 10000 : 0);
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

    // plocate's index can lag behind the real filesystem (it only updates via
    // updatedb); if it comes up empty, fall back to a live, home-scoped search
    Process {
        id: liveFallback
        property var lines: []
        property string runningQuery: ""

        function run(q: string): void {
            liveFallback.runningQuery = q;
            liveFallback.lines = [];
            liveFallback.command = ["fd", "--max-results", "200", "-i", "--", q, Paths.home];
            liveFallback.running = true;
        }

        stdout: SplitParser {
            onRead: data => {
                if (!data)
                    return;
                liveFallback.lines.push(data);
            }
        }

        onRunningChanged: {
            if (liveFallback.running || liveFallback.runningQuery !== root.lastQuery)
                return;

            if (liveFallback.lines.length === 0) {
                root.searching = false;
                root.results = [];
                return;
            }

            statProc.run(liveFallback.runningQuery, liveFallback.lines);
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
