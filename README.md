# smalltools

Small, self-contained browser tools. Each tool is a single HTML file with no dependencies.

| Tool | File | What it does |
| --- | --- | --- |
| Bitwise combination table | [bitwise-table.html](bitwise-table.html) | Builds a Markdown table with one row for every combination of up to 8 two-state fields |
| Tree leaf paths | [tree-leaves.html](tree-leaves.html) | Turns an indented list into one row per leaf, named by its full path, with a flag bit per leaf |
| Flag decoder | [flag-decoder.html](flag-decoder.html) | Shows which flags are set in an int, binary or hex value, and builds a value by ticking flags |
| Table converter | [table-converter.html](table-converter.html) | Reads a pasted Markdown, CSV (comma or semicolon) or Excel/Word table and copies it out as Markdown, CSV, Excel or Word |
| Pairwise test cases | [pairwise.html](pairwise.html) | Builds a small set of test rows that covers every pair of values across fields with any number of values, instead of every combination |
| Decision table | [decision-table.html](decision-table.html) | Every combination of up to 8 two-state fields plus an Expected result column, filled in by simple first-match rules with a default |
| Timestamp converter | [timestamp-converter.html](timestamp-converter.html) | Converts Unix timestamps and dates between formats and time zones, and shows the difference between two timestamps |
| UUID generator | [uuid-generator.html](uuid-generator.html) | Generates UUID v4 and v7 in bulk in several formats, and decodes the version and time from an existing UUID |
| Cron explainer | [cron-explainer.html](cron-explainer.html) | Explains a Unix, six-field or Quartz cron expression in plain English and lists its next runs in any time zone |
| QR code generator | [qr-code.html](qr-code.html) | Builds a QR code from text, a link or Wi-Fi details, and saves it as PNG or SVG |
| Color picker and contrast checker | [color-picker.html](color-picker.html) | Picks a color and converts it between HEX, RGB, HSL, HWB and OKLCH, checks two colors against the WCAG contrast rules, and suggests the closest colors that pass |
| IP subnet calculator | [subnet-calculator.html](subnet-calculator.html) | Works out the network, mask, range and size of an IPv4 or IPv6 address, splits it into subnets, and checks whether an address belongs to it |
| IPv6 guide and quiz | [ipv6-guide.html](ipv6-guide.html) | Explains IPv6 addresses and how IPv6 differs from IPv4, shows the parts of any address, and has shortening practice and a quiz |

`index.html` is a start page that links to every tool listed in `tools.json`.
To add a tool, drop its HTML file in the repo and add an entry to `tools.json`:

```json
{ "file": "my-tool.html", "title": "Optional link text" }
```

`index.html` reads `tools.json` with `fetch()`, so open it through a web server
(for example GitHub Pages or `python3 -m http.server`), not straight from disk.

## Releases

Every push to `main` creates a GitHub Release with a zip of all the tool files
(everything in the repo except the `.github` folder). Tags look like
`v2026.11.03-12`: the date of the push plus the workflow run number.
The workflow lives in `.github/workflows/release-on-push.yml`.
