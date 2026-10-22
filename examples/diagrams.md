# Diagrams

` ```mermaid ` blocks are drawn as diagrams, natively: no browser, no
JavaScript. They follow light and dark mode. A block that cannot be drawn
stays visible as its source.

## Flowchart

```mermaid
flowchart LR
    A[Markdown file] --> B{Quick Look}
    B -->|Space| C[Preview panel]
    B -->|Column view| D[Preview pane]
    B -->|Icon view| E[Thumbnail]
```

## Sequence

```mermaid
sequenceDiagram
    participant Finder
    participant Extension
    participant Core as Rust core
    Finder->>Extension: preview request
    Extension->>Core: render Markdown
    Core-->>Extension: layout (~3 ms)
    Extension-->>Finder: first screen
    Note right of Core: diagrams are drawn<br/>in the background
```

## Class

```mermaid
classDiagram
    class NativeCell {
        +descent
        +size(lineWidth)
        +draw(rect)
    }
    NativeCell <|-- MathCell
    NativeCell <|-- ImageCell
    NativeCell <|-- DiagramCell
```

## State

```mermaid
stateDiagram-v2
    [*] --> Parsed
    Parsed --> Shown: first screen
    Shown --> Complete: rest of the document
    Complete --> [*]
```

## Entity relationship

```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ LINE-ITEM : contains
```

## Pie

```mermaid
pie title Time to open a preview
    "Parse" : 3
    "Build" : 8
    "Layout" : 19
```

## Mind map

```mermaid
mindmap
  root((MD QuickLook))
    Previews
      Space panel
      Column view
    Thumbnails
    Math
    Diagrams
```
