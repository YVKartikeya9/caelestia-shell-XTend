pragma Singleton

import Quickshell

// Caches Exa answers by query so retyping/backspacing back to a query
// already searched doesn't re-spend an API call. Lives as a singleton
// (rather than on GoogleItem itself) because the item is destroyed and
// recreated every time the launcher closes and reopens.
//
// Bounded two ways: entries older than ttlMs are treated as expired, and
// the map is capped at maxEntries via LRU eviction (a Map preserves
// insertion order, and get()/set() both re-insert to bump recency, so the
// first key is always the least-recently-used one).
Singleton {
    id: root

    readonly property int maxEntries: 100
    readonly property int ttlMs: 60 * 60 * 1000 // 1 hour

    property var entries: new Map()

    function get(query: string): var {
        const entry = root.entries.get(query);
        if (!entry)
            return null;

        if (Date.now() - entry.timestamp > root.ttlMs) {
            root.entries.delete(query);
            return null;
        }

        root.entries.delete(query);
        root.entries.set(query, entry);
        return entry;
    }

    function set(query: string, answer: string, citations: var): void {
        root.entries.delete(query);
        root.entries.set(query, { answer, citations, timestamp: Date.now() });

        while (root.entries.size > root.maxEntries)
            root.entries.delete(root.entries.keys().next().value);
    }
}
