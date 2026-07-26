// Backwards-compatible umbrella for existing applications.
// New editor-only integrations should import NativeBlockEditorEngine and
// NativeBlockEditorUI directly, avoiding the optional library/SQLite layer.
@_exported import NativeBlockEditorEngine
@_exported import NativeBlockEditorLibrary
