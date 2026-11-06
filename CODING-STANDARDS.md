# Coding standards

- Use Swift 6 and Apple frameworks. Ask before introducing a third-party application dependency.
- Keep mutable persistence and UI state on their declared actor; make cross-actor payloads explicit and Sendable.
- Keep modules narrow at their public boundary and cohesive internally. Prefer behavior behind a small interface.
- Test observable behavior, not private implementation details. Reproduce bugs with a failing regression test when feasible.
- Preserve every clipboard representation consistently. Never log clipboard contents or MCP tokens.
- Shared-board object graphs must never relate into private history. Permission changes require explicit local consent.
- Surface persistence errors; never silently delete or recreate a corrupt library.
- Maintain native accessibility, keyboard behavior, semantic colors and Reduce Motion support.
- Keep generated project/configuration output reproducible through Scripts.
- Report exact checks and remaining acceptance gates; do not infer production readiness from a successful build.
