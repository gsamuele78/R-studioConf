# scripts/tools/docs_site/mkdocs_hooks.py — MkDocs build hooks for the docs site (ADR-0001).
#
# docs/ links to repo files outside docs/ (CHANGELOG.md, config/, scripts/, ...)
# with relative paths so they work on GitHub and in the docx build. Those files
# are not part of the site, so MkDocs strict mode would reject the links. This
# hook rewrites ONLY links whose target resolves outside docs/ into absolute
# GitHub blob URLs. Links between pages inside docs/ are left untouched, so a
# genuinely broken internal link still fails the strict build. A link outside
# docs/ whose target does not exist in the checkout is also left untouched, so
# strict mode reports it instead of publishing a dead GitHub URL.
from __future__ import annotations

import os
import posixpath
import re

# Inline Markdown links and images: ](target) or ](target "title") or ](<target>)
_LINK = re.compile(r"\]\(\s*<?([^)\s>]+)>?((?:\s+\"[^\"]*\")?)\s*\)")
_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def _outside_docs(page_src: str, target: str) -> str | None:
    """Return the repo-relative path if target escapes docs/, else None."""
    if target.startswith(("#", "/")) or _SCHEME.match(target):
        return None
    path, _, frag = target.partition("#")
    if not path:
        return None
    resolved = posixpath.normpath(posixpath.join("docs", posixpath.dirname(page_src), path))
    if resolved == "docs" or resolved.startswith("docs/") or resolved.startswith(".."):
        return None
    return resolved + (f"#{frag}" if frag else "")


def on_page_markdown(markdown, page, config, files):  # noqa: ARG001 (MkDocs hook signature)
    repo_root = os.path.dirname(os.path.abspath(config["config_file_path"]))
    base = config.get("repo_url", "").rstrip("/")
    branch = config.get("extra", {}).get("source_branch", "main")
    if not base:
        return markdown

    def repl(m: re.Match) -> str:
        repo_path = _outside_docs(page.file.src_uri, m.group(1))
        if repo_path is None:
            return m.group(0)
        if not os.path.exists(os.path.join(repo_root, repo_path.partition("#")[0])):
            return m.group(0)
        return f"]({base}/blob/{branch}/{repo_path}{m.group(2)})"

    return _LINK.sub(repl, markdown)
