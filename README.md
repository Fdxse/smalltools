# smalltools

Small, self-contained browser tools. Each tool is a single HTML file with no dependencies.

| Tool | File | What it does |
| --- | --- | --- |
| Bitwise combination table | [bitwise-table.html](bitwise-table.html) | Builds a Markdown table with one row for every combination of up to 8 two-state fields |
| Tree leaf paths | [tree-leaves.html](tree-leaves.html) | Turns an indented list into one row per leaf, named by its full path, with a flag bit per leaf |
| Flag decoder | [flag-decoder.html](flag-decoder.html) | Shows which flags are set in an int, binary or hex value, and builds a value by ticking flags |
| Table converter | [table-converter.html](table-converter.html) | Reads a pasted Markdown, CSV (comma or semicolon) or Excel/Word table and copies it out as Markdown, CSV, Excel or Word |
| Pairwise test cases | [pairwise.html](pairwise.html) | Builds a small set of test rows that covers every pair of values across fields with any number of values, instead of every combination |

`index.html` is a start page that links to every tool listed in `tools.json`.
To add a tool, drop its HTML file in the repo and add an entry to `tools.json`:

```json
{ "file": "my-tool.html", "title": "Optional link text" }
```

`index.html` reads `tools.json` with `fetch()`, so open it through a web server
(for example GitHub Pages or `python3 -m http.server`), not straight from disk.
