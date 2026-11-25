#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(".").resolve()
errors: list[str] = []

required_files = [
    root / "README.md",
    root / "profile" / "README.md",
    root / ".gitignore",
    root / "scripts" / "verify-local.sh",
]

for path in required_files:
    if not path.is_file():
        errors.append(f"Missing required file: {path.relative_to(root)}")
    elif path.stat().st_size == 0:
        errors.append(f"File is empty: {path.relative_to(root)}")

# Disallow GitHub Actions workflows in .github (reserved per GivOps policy)
workflows_dir = root / ".github" / "workflows"
if workflows_dir.exists():
    errors.append("Forbidden .github/workflows directory present")
for wf in root.rglob("*"):
    if wf.is_file() and ".github/workflows" in wf.as_posix():
        errors.append(f"Forbidden workflow file: {wf.relative_to(root)}")

markdown_files = [root / "README.md", root / "profile" / "README.md"]
text_by_file: dict[pathlib.Path, str] = {}

for path in markdown_files:
    if not path.is_file():
        continue
    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        errors.append(f"Invalid UTF-8 in {path.relative_to(root)}: {exc}")
        continue
    text_by_file[path] = content

# Check LF endings, trailing whitespace, and conflict markers across authored text files
for path in required_files:
    if not path.is_file():
        continue
    raw = path.read_bytes()
    if b"\r" in raw:
        errors.append(f"CRLF/CR line ending found in {path.relative_to(root)}")
    for lineno, line in enumerate(raw.decode("utf-8").splitlines(), start=1):
        if line != line.rstrip(" \t"):
            errors.append(f"Trailing whitespace in {path.relative_to(root)}:{lineno}")
        if re.match(r"^(<{7}|={7}|>{7})(\s|$)", line):
            errors.append(f"Git conflict marker in {path.relative_to(root)}:{lineno}")

# Validate raw.githubusercontent.com asset URLs and ensure no orphaned assets
raw_prefix = "https://raw.githubusercontent.com/givops/.github/main/"
referenced_assets: set[pathlib.Path] = set()
raw_url_re = re.compile(r"https://raw\.githubusercontent\.com/givops/\.github/main/([^\s\"'<>)]+)")

for path, content in text_by_file.items():
    for match in raw_url_re.finditer(content):
        rel = match.group(1)
        target = (root / rel).resolve()
        if not str(target).startswith(str(root) + "/") or not target.is_file():
            errors.append(f"Broken raw asset URL in {path.relative_to(root)}: {match.group(0)}")
        elif target.stat().st_size == 0:
            errors.append(f"Empty raw asset target in {path.relative_to(root)}: {rel}")
        else:
            referenced_assets.add(target)

assets_dir = root / "profile" / "assets"
if not assets_dir.is_dir():
    errors.append("Missing profile/assets directory")
else:
    asset_files = sorted(p.resolve() for p in assets_dir.iterdir() if p.is_file())
    if not asset_files:
        errors.append("No asset files found in profile/assets")
    for asset in asset_files:
        if asset.stat().st_size == 0:
            errors.append(f"Empty asset file: {asset.relative_to(root)}")
        if asset not in referenced_assets:
            errors.append(f"Unreferenced asset in profile/assets: {asset.relative_to(root)}")

# Validate local relative Markdown and HTML links
md_link_re = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
html_attr_re = re.compile(r"""(?:href|src)=["']([^"']+)["']""")

for path, content in text_by_file.items():
    candidates = [m.group(1).strip() for m in md_link_re.finditer(content)]
    candidates.extend(m.group(1).strip() for m in html_attr_re.finditer(content))
    for target in candidates:
        if (
            not target
            or target.startswith("#")
            or target.startswith("http://")
            or target.startswith("https://")
            or target.startswith("mailto:")
        ):
            continue
        clean = target.split("#", 1)[0].split("?", 1)[0]
        resolved = (path.parent / clean).resolve()
        if not str(resolved).startswith(str(root) + "/") or not resolved.exists():
            errors.append(f"Broken relative link in {path.relative_to(root)}: {target}")

# Public-boundary hygiene: only allow listed public GitHub repositories under givops/
allowed_public_repos = {
    ".github",
    "adapter-sdk",
    "adapter-github",
    "adapter-gitlab",
    "adapter-jira",
    "adapter-youtrack",
    "adapter-backlog",
    "publishd-runner-examples",
}
gh_repo_re = re.compile(r"https://github\.com/givops/([A-Za-z0-9._-]+)")
givops_slug_re = re.compile(r"(?<![A-Za-z0-9.])givops/([A-Za-z0-9._-]+)")
forbidden_repo_names = [
    "back-spring",
    "front-angular",
    "public-website",
    "test-fixtures",
    "dev-tools",
    "legacy-back-node",
    "legacy-front-angular",
    "legacy-publishd-apt",
    "adapter-backlog-md",
]

for path, content in text_by_file.items():
    for match in gh_repo_re.finditer(content):
        repo_name = match.group(1)
        if repo_name not in allowed_public_repos:
            errors.append(f"Non-allowlisted GivOps GitHub repository URL in {path.relative_to(root)}: {match.group(0)}")
    for match in givops_slug_re.finditer(content):
        repo_name = match.group(1)
        if repo_name not in allowed_public_repos:
            errors.append(f"Non-allowlisted GivOps repository reference in {path.relative_to(root)}: {match.group(0)}")
    lower = content.lower()
    for forbidden in forbidden_repo_names:
        if re.search(rf"(?<![a-z0-9-]){re.escape(forbidden)}(?![a-z0-9-])", lower):
            errors.append(f"Forbidden internal/retired repository name '{forbidden}' mentioned in {path.relative_to(root)}")

# Validate Mermaid fenced blocks in profile/README.md
profile_text = text_by_file.get(root / "profile" / "README.md", "")
in_mermaid = False
mermaid_blocks: list[list[str]] = []
current_block: list[str] = []
for line in profile_text.splitlines():
    stripped = line.strip()
    if not in_mermaid and stripped == "```mermaid":
        in_mermaid = True
        current_block = []
    elif in_mermaid and stripped == "```":
        in_mermaid = False
        mermaid_blocks.append(current_block)
    elif in_mermaid:
        current_block.append(line)

if in_mermaid:
    errors.append("Unclosed ```mermaid code block in profile/README.md")
if not mermaid_blocks:
    errors.append("Expected at least one ```mermaid diagram block in profile/README.md")

for idx, block in enumerate(mermaid_blocks, start=1):
    non_empty = [ln for ln in block if ln.strip()]
    if len(non_empty) < 2:
        errors.append(f"Mermaid block #{idx} in profile/README.md is empty")
    for ln in non_empty:
        # Disallow HTML tags inside Mermaid node/edge labels (Mermaid syntax guideline)
        if re.search(r"</?[a-zA-Z][^>]*>", ln):
            errors.append(f"HTML tag found inside Mermaid block #{idx}: {ln.strip()}")

if errors:
    for err in errors:
        print(f"ERROR: {err}", file=sys.stderr)
    sys.exit(1)

print("Verified givops/.github: profile/README.md, README.md, 3 profile/assets, links, public-boundary allowlist, and Mermaid block.")
PY

git diff --check
echo "git diff --check passed."
