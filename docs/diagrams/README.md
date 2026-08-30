# Ember diagram assets

The root [`README.md`](../../README.md) uses pre-rendered PNG files so diagrams display reliably in GitHub's mobile apps and can be reused in articles. Mermaid and Excalidraw files remain the editable sources.

| Diagram | Rendered PNG | Mermaid source | Excalidraw source |
|---|---|---|---|
| Transparency overview | [`ember-transparency-overview.png`](rendered/ember-transparency-overview.png) | [`ember-transparency-overview.mmd`](mermaid/ember-transparency-overview.mmd) | [`ember-app-architecture.excalidraw`](ember-app-architecture.excalidraw) |
| Private turn lifecycle | [`ember-turn-lifecycle.png`](rendered/ember-turn-lifecycle.png) | [`ember-turn-lifecycle.mmd`](mermaid/ember-turn-lifecycle.mmd) | Related: [`ember-app-architecture.excalidraw`](ember-app-architecture.excalidraw) |
| Memory pipeline | [`ember-memory-pipeline.png`](rendered/ember-memory-pipeline.png) | [`ember-memory-pipeline.mmd`](mermaid/ember-memory-pipeline.mmd) | [`ember-memory-architecture.excalidraw`](ember-memory-architecture.excalidraw) |
| Token accounting | [`ember-token-accounting.png`](rendered/ember-token-accounting.png) | [`ember-token-accounting.mmd`](mermaid/ember-token-accounting.mmd) | [`ember-context-window.excalidraw`](ember-context-window.excalidraw) |
| System architecture | [`ember-system-architecture.png`](rendered/ember-system-architecture.png) | [`ember-system-architecture.mmd`](mermaid/ember-system-architecture.mmd) | [`ember-app-architecture.excalidraw`](ember-app-architecture.excalidraw) |

## Regenerate the PNG exports

The committed images were generated with Mermaid CLI 11.16.0, a 1,400-pixel viewport, and a 2× scale. The shared [`mermaid-config.json`](mermaid-config.json) supplies the Ember color and typography theme.

From the repository root:

```bash
mkdir -p docs/diagrams/rendered

for diagram_path in docs/diagrams/mermaid/*.mmd; do
  diagram_name=${diagram_path##*/}
  diagram_name=${diagram_name%.mmd}
  npx --yes @mermaid-js/mermaid-cli@11.16.0 \
    -i "$diagram_path" \
    -o "docs/diagrams/rendered/${diagram_name}.png" \
    -c docs/diagrams/mermaid-config.json \
    -b white -w 1400 -s 2 -q
done
```

Edit the `.mmd` or `.excalidraw` source rather than a rendered PNG. Regenerate and visually inspect every affected export before committing it.
