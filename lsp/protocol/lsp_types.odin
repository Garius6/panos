package lsp_protocol

// Generated from LSP metaModel.json 3.17.0 by generate.py. Do not edit by hand.

// Base types

DocumentUri :: distinct string

URI :: distinct string

// Enumerations

// A set of predefined token types. This set is not fixed
// an clients can specify additional token types via the
// corresponding client capabilities.
// 
// @since 3.16.0
SemanticTokenTypes :: distinct string
SemanticTokenTypes_Namespace :: SemanticTokenTypes("namespace")
// Represents a generic type. Acts as a fallback for types which can't be mapped to
// a specific type like class or enum.
SemanticTokenTypes_Type :: SemanticTokenTypes("type")
SemanticTokenTypes_Class :: SemanticTokenTypes("class")
SemanticTokenTypes_Enum :: SemanticTokenTypes("enum")
SemanticTokenTypes_Interface :: SemanticTokenTypes("interface")
SemanticTokenTypes_Struct :: SemanticTokenTypes("struct")
SemanticTokenTypes_TypeParameter :: SemanticTokenTypes("typeParameter")
SemanticTokenTypes_Parameter :: SemanticTokenTypes("parameter")
SemanticTokenTypes_Variable :: SemanticTokenTypes("variable")
SemanticTokenTypes_Property :: SemanticTokenTypes("property")
SemanticTokenTypes_EnumMember :: SemanticTokenTypes("enumMember")
SemanticTokenTypes_Event :: SemanticTokenTypes("event")
SemanticTokenTypes_Function :: SemanticTokenTypes("function")
SemanticTokenTypes_Method :: SemanticTokenTypes("method")
SemanticTokenTypes_Macro :: SemanticTokenTypes("macro")
SemanticTokenTypes_Keyword :: SemanticTokenTypes("keyword")
SemanticTokenTypes_Modifier :: SemanticTokenTypes("modifier")
SemanticTokenTypes_Comment :: SemanticTokenTypes("comment")
SemanticTokenTypes_String :: SemanticTokenTypes("string")
SemanticTokenTypes_Number :: SemanticTokenTypes("number")
SemanticTokenTypes_Regexp :: SemanticTokenTypes("regexp")
SemanticTokenTypes_Operator :: SemanticTokenTypes("operator")
// @since 3.17.0
SemanticTokenTypes_Decorator :: SemanticTokenTypes("decorator")

// A set of predefined token modifiers. This set is not fixed
// an clients can specify additional token types via the
// corresponding client capabilities.
// 
// @since 3.16.0
SemanticTokenModifiers :: distinct string
SemanticTokenModifiers_Declaration :: SemanticTokenModifiers("declaration")
SemanticTokenModifiers_Definition :: SemanticTokenModifiers("definition")
SemanticTokenModifiers_Readonly :: SemanticTokenModifiers("readonly")
SemanticTokenModifiers_Static :: SemanticTokenModifiers("static")
SemanticTokenModifiers_Deprecated :: SemanticTokenModifiers("deprecated")
SemanticTokenModifiers_Abstract :: SemanticTokenModifiers("abstract")
SemanticTokenModifiers_Async :: SemanticTokenModifiers("async")
SemanticTokenModifiers_Modification :: SemanticTokenModifiers("modification")
SemanticTokenModifiers_Documentation :: SemanticTokenModifiers("documentation")
SemanticTokenModifiers_DefaultLibrary :: SemanticTokenModifiers("defaultLibrary")

// The document diagnostic report kinds.
// 
// @since 3.17.0
DocumentDiagnosticReportKind :: distinct string
// A diagnostic report with a full
// set of problems.
DocumentDiagnosticReportKind_Full :: DocumentDiagnosticReportKind("full")
// A report indicating that the last
// returned report is still accurate.
DocumentDiagnosticReportKind_Unchanged :: DocumentDiagnosticReportKind("unchanged")

// Predefined error codes.
ErrorCodes :: enum {
	ParseError = -32700,
	InvalidRequest = -32600,
	MethodNotFound = -32601,
	InvalidParams = -32602,
	InternalError = -32603,
	// Error code indicating that a server received a notification or
	// request before the server has received the `initialize` request.
	ServerNotInitialized = -32002,
	UnknownErrorCode = -32001,
}

LSPErrorCodes :: enum {
	// A request failed but it was syntactically correct, e.g the
	// method name was known and the parameters were valid. The error
	// message should contain human readable information about why
	// the request failed.
	// 
	// @since 3.17.0
	RequestFailed = -32803,
	// The server cancelled the request. This error code should
	// only be used for requests that explicitly support being
	// server cancellable.
	// 
	// @since 3.17.0
	ServerCancelled = -32802,
	// The server detected that the content of a document got
	// modified outside normal conditions. A server should
	// NOT send this error code if it detects a content change
	// in it unprocessed messages. The result even computed
	// on an older state might still be useful for the client.
	// 
	// If a client decides that a result is not of any use anymore
	// the client should cancel the request.
	ContentModified = -32801,
	// The client has canceled a request and a server has detected
	// the cancel.
	RequestCancelled = -32800,
}

// A set of predefined range kinds.
FoldingRangeKind :: distinct string
// Folding range for a comment
FoldingRangeKind_Comment :: FoldingRangeKind("comment")
// Folding range for an import or include
FoldingRangeKind_Imports :: FoldingRangeKind("imports")
// Folding range for a region (e.g. `#region`)
FoldingRangeKind_Region :: FoldingRangeKind("region")

// A symbol kind.
SymbolKind :: enum {
	File = 1,
	Module = 2,
	Namespace = 3,
	Package = 4,
	Class = 5,
	Method = 6,
	Property = 7,
	Field = 8,
	Constructor = 9,
	Enum = 10,
	Interface = 11,
	Function = 12,
	Variable = 13,
	Constant = 14,
	String = 15,
	Number = 16,
	Boolean = 17,
	Array = 18,
	Object = 19,
	Key = 20,
	Null = 21,
	EnumMember = 22,
	Struct = 23,
	Event = 24,
	Operator = 25,
	TypeParameter = 26,
}

// Symbol tags are extra annotations that tweak the rendering of a symbol.
// 
// @since 3.16
SymbolTag :: enum {
	// Render a symbol as obsolete, usually using a strike-out.
	Deprecated = 1,
}

// Moniker uniqueness level to define scope of the moniker.
// 
// @since 3.16.0
UniquenessLevel :: distinct string
// The moniker is only unique inside a document
UniquenessLevel_Document :: UniquenessLevel("document")
// The moniker is unique inside a project for which a dump got created
UniquenessLevel_Project :: UniquenessLevel("project")
// The moniker is unique inside the group to which a project belongs
UniquenessLevel_Group :: UniquenessLevel("group")
// The moniker is unique inside the moniker scheme.
UniquenessLevel_Scheme :: UniquenessLevel("scheme")
// The moniker is globally unique
UniquenessLevel_Global :: UniquenessLevel("global")

// The moniker kind.
// 
// @since 3.16.0
MonikerKind :: distinct string
// The moniker represent a symbol that is imported into a project
MonikerKind_Import :: MonikerKind("import")
// The moniker represents a symbol that is exported from a project
MonikerKind_Export :: MonikerKind("export")
// The moniker represents a symbol that is local to a project (e.g. a local
// variable of a function, a class not visible outside the project, ...)
MonikerKind_Local :: MonikerKind("local")

// Inlay hint kinds.
// 
// @since 3.17.0
InlayHintKind :: enum {
	// An inlay hint that for a type annotation.
	Type = 1,
	// An inlay hint that is for a parameter.
	Parameter = 2,
}

// The message type
MessageType :: enum {
	// An error message.
	Error = 1,
	// A warning message.
	Warning = 2,
	// An information message.
	Info = 3,
	// A log message.
	Log = 4,
	// A debug message.
	// 
	// @since 3.18.0
	Debug = 5,
}

// Defines how the host (editor) should sync
// document changes to the language server.
TextDocumentSyncKind :: enum {
	// Documents should not be synced at all.
	None = 0,
	// Documents are synced by always sending the full content
	// of the document.
	Full = 1,
	// Documents are synced by sending the full content on open.
	// After that only incremental updates to the document are
	// send.
	Incremental = 2,
}

// Represents reasons why a text document is saved.
TextDocumentSaveReason :: enum {
	// Manually triggered, e.g. by the user pressing save, by starting debugging,
	// or by an API call.
	Manual = 1,
	// Automatic after a delay.
	AfterDelay = 2,
	// When the editor lost focus.
	FocusOut = 3,
}

// The kind of a completion entry.
CompletionItemKind :: enum {
	Text = 1,
	Method = 2,
	Function = 3,
	Constructor = 4,
	Field = 5,
	Variable = 6,
	Class = 7,
	Interface = 8,
	Module = 9,
	Property = 10,
	Unit = 11,
	Value = 12,
	Enum = 13,
	Keyword = 14,
	Snippet = 15,
	Color = 16,
	File = 17,
	Reference = 18,
	Folder = 19,
	EnumMember = 20,
	Constant = 21,
	Struct = 22,
	Event = 23,
	Operator = 24,
	TypeParameter = 25,
}

// Completion item tags are extra annotations that tweak the rendering of a completion
// item.
// 
// @since 3.15.0
CompletionItemTag :: enum {
	// Render a completion as obsolete, usually using a strike-out.
	Deprecated = 1,
}

// Defines whether the insert text in a completion item should be interpreted as
// plain text or a snippet.
InsertTextFormat :: enum {
	// The primary text to be inserted is treated as a plain string.
	PlainText = 1,
	// The primary text to be inserted is treated as a snippet.
	// 
	// A snippet can define tab stops and placeholders with `$1`, `$2`
	// and `${3:foo}`. `$0` defines the final tab stop, it defaults to
	// the end of the snippet. Placeholders with equal identifiers are linked,
	// that is typing in one will update others too.
	// 
	// See also: https://microsoft.github.io/language-server-protocol/specifications/specification-current/#snippet_syntax
	Snippet = 2,
}

// How whitespace and indentation is handled during completion
// item insertion.
// 
// @since 3.16.0
InsertTextMode :: enum {
	// The insertion or replace strings is taken as it is. If the
	// value is multi line the lines below the cursor will be
	// inserted using the indentation defined in the string value.
	// The client will not apply any kind of adjustments to the
	// string.
	AsIs = 1,
	// The editor adjusts leading whitespace of new lines so that
	// they match the indentation up to the cursor of the line for
	// which the item is accepted.
	// 
	// Consider a line like this: <2tabs><cursor><3tabs>foo. Accepting a
	// multi line completion item is indented using 2 tabs and all
	// following lines inserted will be indented using 2 tabs as well.
	AdjustIndentation = 2,
}

// A document highlight kind.
DocumentHighlightKind :: enum {
	// A textual occurrence.
	Text = 1,
	// Read-access of a symbol, like reading a variable.
	Read = 2,
	// Write-access of a symbol, like writing to a variable.
	Write = 3,
}

// A set of predefined code action kinds
CodeActionKind :: distinct string
// Empty kind.
CodeActionKind_Empty :: CodeActionKind("")
// Base kind for quickfix actions: 'quickfix'
CodeActionKind_QuickFix :: CodeActionKind("quickfix")
// Base kind for refactoring actions: 'refactor'
CodeActionKind_Refactor :: CodeActionKind("refactor")
// Base kind for refactoring extraction actions: 'refactor.extract'
// 
// Example extract actions:
// 
// - Extract method
// - Extract function
// - Extract variable
// - Extract interface from class
// - ...
CodeActionKind_RefactorExtract :: CodeActionKind("refactor.extract")
// Base kind for refactoring inline actions: 'refactor.inline'
// 
// Example inline actions:
// 
// - Inline function
// - Inline variable
// - Inline constant
// - ...
CodeActionKind_RefactorInline :: CodeActionKind("refactor.inline")
// Base kind for refactoring rewrite actions: 'refactor.rewrite'
// 
// Example rewrite actions:
// 
// - Convert JavaScript function to class
// - Add or remove parameter
// - Encapsulate field
// - Make method static
// - Move method to base class
// - ...
CodeActionKind_RefactorRewrite :: CodeActionKind("refactor.rewrite")
// Base kind for source actions: `source`
// 
// Source code actions apply to the entire file.
CodeActionKind_Source :: CodeActionKind("source")
// Base kind for an organize imports source action: `source.organizeImports`
CodeActionKind_SourceOrganizeImports :: CodeActionKind("source.organizeImports")
// Base kind for auto-fix source actions: `source.fixAll`.
// 
// Fix all actions automatically fix errors that have a clear fix that do not require user input.
// They should not suppress errors or perform unsafe fixes such as generating new types or classes.
// 
// @since 3.15.0
CodeActionKind_SourceFixAll :: CodeActionKind("source.fixAll")

TraceValues :: distinct string
// Turn tracing off.
TraceValues_Off :: TraceValues("off")
// Trace messages only.
TraceValues_Messages :: TraceValues("messages")
// Verbose message tracing.
TraceValues_Verbose :: TraceValues("verbose")

// Describes the content type that a client supports in various
// result literals like `Hover`, `ParameterInfo` or `CompletionItem`.
// 
// Please note that `MarkupKinds` must not start with a `$`. This kinds
// are reserved for internal usage.
MarkupKind :: distinct string
// Plain text is supported as a content format
MarkupKind_PlainText :: MarkupKind("plaintext")
// Markdown is supported as a content format
MarkupKind_Markdown :: MarkupKind("markdown")

// Describes how an {@link InlineCompletionItemProvider inline completion provider} was triggered.
// 
// @since 3.18.0
// @proposed
InlineCompletionTriggerKind :: enum {
	// Completion was triggered explicitly by a user gesture.
	Invoked = 0,
	// Completion was triggered automatically while editing.
	Automatic = 1,
}

// A set of predefined position encoding kinds.
// 
// @since 3.17.0
PositionEncodingKind :: distinct string
// Character offsets count UTF-8 code units (e.g. bytes).
PositionEncodingKind_UTF8 :: PositionEncodingKind("utf-8")
// Character offsets count UTF-16 code units.
// 
// This is the default and must always be supported
// by servers
PositionEncodingKind_UTF16 :: PositionEncodingKind("utf-16")
// Character offsets count UTF-32 code units.
// 
// Implementation note: these are the same as Unicode codepoints,
// so this `PositionEncodingKind` may also be used for an
// encoding-agnostic representation of character offsets.
PositionEncodingKind_UTF32 :: PositionEncodingKind("utf-32")

// The file event type
FileChangeType :: enum {
	// The file got created.
	Created = 1,
	// The file got changed.
	Changed = 2,
	// The file got deleted.
	Deleted = 3,
}

WatchKind :: enum {
	// Interested in create events.
	Create = 1,
	// Interested in change events
	Change = 2,
	// Interested in delete events
	Delete = 4,
}

// The diagnostic's severity.
DiagnosticSeverity :: enum {
	// Reports an error.
	Error = 1,
	// Reports a warning.
	Warning = 2,
	// Reports an information.
	Information = 3,
	// Reports a hint.
	Hint = 4,
}

// The diagnostic tags.
// 
// @since 3.15.0
DiagnosticTag :: enum {
	// Unused or unnecessary code.
	// 
	// Clients are allowed to render diagnostics with this tag faded out instead of having
	// an error squiggle.
	Unnecessary = 1,
	// Deprecated or obsolete code.
	// 
	// Clients are allowed to rendered diagnostics with this tag strike through.
	Deprecated = 2,
}

// How a completion was triggered
CompletionTriggerKind :: enum {
	// Completion was triggered by typing an identifier (24x7 code
	// complete), manual invocation (e.g Ctrl+Space) or via API.
	Invoked = 1,
	// Completion was triggered by a trigger character specified by
	// the `triggerCharacters` properties of the `CompletionRegistrationOptions`.
	TriggerCharacter = 2,
	// Completion was re-triggered as current completion list is incomplete
	TriggerForIncompleteCompletions = 3,
}

// How a signature help was triggered.
// 
// @since 3.15.0
SignatureHelpTriggerKind :: enum {
	// Signature help was invoked manually by the user or by a command.
	Invoked = 1,
	// Signature help was triggered by a trigger character.
	TriggerCharacter = 2,
	// Signature help was triggered by the cursor moving or by the document content changing.
	ContentChange = 3,
}

// The reason why code actions were requested.
// 
// @since 3.17.0
CodeActionTriggerKind :: enum {
	// Code actions were explicitly requested by the user or by an extension.
	Invoked = 1,
	// Code actions were requested automatically.
	// 
	// This typically happens when current selection in a file changes, but can
	// also be triggered when file content changes.
	Automatic = 2,
}

// A pattern kind describing if a glob pattern matches a file a folder or
// both.
// 
// @since 3.16.0
FileOperationPatternKind :: distinct string
// The pattern matches a file only.
FileOperationPatternKind_File :: FileOperationPatternKind("file")
// The pattern matches a folder only.
FileOperationPatternKind_Folder :: FileOperationPatternKind("folder")

// A notebook cell kind.
// 
// @since 3.17.0
NotebookCellKind :: enum {
	// A markup-cell is formatted source that is used for display.
	Markup = 1,
	// A code-cell is source code.
	Code = 2,
}

ResourceOperationKind :: distinct string
// Supports creating new files and folders.
ResourceOperationKind_Create :: ResourceOperationKind("create")
// Supports renaming existing files and folders.
ResourceOperationKind_Rename :: ResourceOperationKind("rename")
// Supports deleting existing files and folders.
ResourceOperationKind_Delete :: ResourceOperationKind("delete")

FailureHandlingKind :: distinct string
// Applying the workspace change is simply aborted if one of the changes provided
// fails. All operations executed before the failing operation stay executed.
FailureHandlingKind_Abort :: FailureHandlingKind("abort")
// All operations are executed transactional. That means they either all
// succeed or no changes at all are applied to the workspace.
FailureHandlingKind_Transactional :: FailureHandlingKind("transactional")
// If the workspace edit contains only textual file changes they are executed transactional.
// If resource changes (create, rename or delete file) are part of the change the failure
// handling strategy is abort.
FailureHandlingKind_TextOnlyTransactional :: FailureHandlingKind("textOnlyTransactional")
// The client tries to undo the operations already executed. But there is no
// guarantee that this is succeeding.
FailureHandlingKind_Undo :: FailureHandlingKind("undo")

PrepareSupportDefaultBehavior :: enum {
	// The client's default behavior is to select the identifier
	// according the to language's syntax rule.
	Identifier = 1,
}

TokenFormat :: distinct string
TokenFormat_Relative :: TokenFormat("relative")

// Type aliases

// The definition of a symbol represented as one or many {@link Location locations}.
// For most programming languages there is only one location at which a symbol is
// defined.
// 
// Servers should prefer returning `DefinitionLink` over `Definition` if supported
// by the client.
Definition :: union {Location, []Location}

// Information about where a symbol is defined.
// 
// Provides additional metadata over normal {@link Location location} definitions, including the range of
// the defining symbol
DefinitionLink :: LocationLink

// LSP arrays.
// @since 3.17.0
LSPArray :: []LSPAny

// The LSP any type.
// Please note that strictly speaking a property with the value `undefined`
// can't be converted into JSON preserving the property name. However for
// convenience it is allowed and assumed that all these properties are
// optional as well.
// @since 3.17.0
LSPAny :: union {LSPObject, LSPArray, string, i32, u32, f64, bool}

// The declaration of a symbol representation as one or many {@link Location locations}.
Declaration :: union {Location, []Location}

// Information about where a symbol is declared.
// 
// Provides additional metadata over normal {@link Location location} declarations, including the range of
// the declaring symbol.
// 
// Servers should prefer returning `DeclarationLink` over `Declaration` if supported
// by the client.
DeclarationLink :: LocationLink

// Inline value information can be provided by different means:
// - directly as a text value (class InlineValueText).
// - as a name to use for a variable lookup (class InlineValueVariableLookup)
// - as an evaluatable expression (class InlineValueEvaluatableExpression)
// The InlineValue types combines all inline value types into one type.
// 
// @since 3.17.0
InlineValue :: union {InlineValueText, InlineValueVariableLookup, InlineValueEvaluatableExpression}

// The result of a document diagnostic pull request. A report can
// either be a full report containing all diagnostics for the
// requested document or an unchanged report indicating that nothing
// has changed in terms of diagnostics in comparison to the last
// pull request.
// 
// @since 3.17.0
DocumentDiagnosticReport :: union {RelatedFullDocumentDiagnosticReport, RelatedUnchangedDocumentDiagnosticReport}

PrepareRenameResult :: union {Range, PrepareRenameResultVariant1, PrepareRenameResultVariant2}

// A document selector is the combination of one or many document filters.
// 
// @sample `let sel:DocumentSelector = [{ language: 'typescript' }, { language: 'json', pattern: '**∕tsconfig.json' }]`;
// 
// The use of a string as a document filter is deprecated @since 3.16.0.
DocumentSelector :: []DocumentFilter

ProgressToken :: union {i32, string}

// An identifier to refer to a change annotation stored with a workspace edit.
ChangeAnnotationIdentifier :: string

// A workspace diagnostic document report.
// 
// @since 3.17.0
WorkspaceDocumentDiagnosticReport :: union {WorkspaceFullDocumentDiagnosticReport, WorkspaceUnchangedDocumentDiagnosticReport}

// An event describing a change to a text document. If only a text is provided
// it is considered to be the full content of the document.
TextDocumentContentChangeEvent :: union {TextDocumentContentChangeEventVariant0, TextDocumentContentChangeEventVariant1}

// MarkedString can be used to render human readable text. It is either a markdown string
// or a code-block that provides a language and a code snippet. The language identifier
// is semantically equal to the optional language identifier in fenced code blocks in GitHub
// issues. See https://help.github.com/articles/creating-and-highlighting-code-blocks/#syntax-highlighting
// 
// The pair of a language and a value is an equivalent to markdown:
// ```${language}
// ${value}
// ```
// 
// Note that markdown strings will be sanitized - that means html will be escaped.
// @deprecated use MarkupContent instead.
MarkedString :: union {string, MarkedStringVariant1}

// A document filter describes a top level text document or
// a notebook cell document.
// 
// @since 3.17.0 - proposed support for NotebookCellTextDocumentFilter.
DocumentFilter :: union {TextDocumentFilter, NotebookCellTextDocumentFilter}

// LSP object definition.
// @since 3.17.0
LSPObject :: map[string]LSPAny

// The glob pattern. Either a string pattern or a relative pattern.
// 
// @since 3.17.0
GlobPattern :: union {Pattern, RelativePattern}

// A document filter denotes a document by different properties like
// the {@link TextDocument.languageId language}, the {@link Uri.scheme scheme} of
// its resource, or a glob-pattern that is applied to the {@link TextDocument.fileName path}.
// 
// Glob patterns can have the following syntax:
// - `*` to match zero or more characters in a path segment
// - `?` to match on one character in a path segment
// - `**` to match any number of path segments, including none
// - `{}` to group sub patterns into an OR expression. (e.g. `**​/*.{ts,js}` matches all TypeScript and JavaScript files)
// - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
// - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
// 
// @sample A language filter that applies to typescript files on disk: `{ language: 'typescript', scheme: 'file' }`
// @sample A language filter that applies to all package.json paths: `{ language: 'json', pattern: '**package.json' }`
// 
// @since 3.17.0
TextDocumentFilter :: union {TextDocumentFilterVariant0, TextDocumentFilterVariant1, TextDocumentFilterVariant2}

// A notebook document filter denotes a notebook document by
// different properties. The properties will be match
// against the notebook's URI (same as with documents)
// 
// @since 3.17.0
NotebookDocumentFilter :: union {NotebookDocumentFilterVariant0, NotebookDocumentFilterVariant1, NotebookDocumentFilterVariant2}

// The glob pattern to watch relative to the base path. Glob patterns can have the following syntax:
// - `*` to match zero or more characters in a path segment
// - `?` to match on one character in a path segment
// - `**` to match any number of path segments, including none
// - `{}` to group conditions (e.g. `**​/*.{ts,js}` matches all TypeScript and JavaScript files)
// - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
// - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
// 
// @since 3.17.0
Pattern :: string

// Anonymous types (literals/tuples/intersections), name derived

SemanticTokensRegistrationOptionsRangeVariant1 :: struct {

}

SemanticTokensRegistrationOptionsFullVariant1 :: struct {
	// The server supports deltas for full documents.
	delta: Maybe(bool) `json:"delta,omitempty"`,
}

InitializeParamsClientInfo :: struct {
	// The name of the client as defined by the client.
	name: string `json:"name"`,
	// The client's version as defined by the client.
	version: Maybe(string) `json:"version,omitempty"`,
}

InitializeResultServerInfo :: struct {
	// The name of the server as defined by the server.
	name: string `json:"name"`,
	// The server's version as defined by the server.
	version: Maybe(string) `json:"version,omitempty"`,
}

CompletionListItemDefaultsEditRangeVariant1 :: struct {
	insert: Range `json:"insert"`,
	replace: Range `json:"replace"`,
}

CompletionListItemDefaults :: struct {
	// A default commit character set.
	// 
	// @since 3.17.0
	commit_characters: Maybe([]string) `json:"commitCharacters,omitempty"`,
	// A default edit range.
	// 
	// @since 3.17.0
	edit_range: Maybe(union {Range, CompletionListItemDefaultsEditRangeVariant1}) `json:"editRange,omitempty"`,
	// A default insert text format.
	// 
	// @since 3.17.0
	insert_text_format: Maybe(InsertTextFormat) `json:"insertTextFormat,omitempty"`,
	// A default insert text mode.
	// 
	// @since 3.17.0
	insert_text_mode: Maybe(InsertTextMode) `json:"insertTextMode,omitempty"`,
	// A default data value.
	// 
	// @since 3.17.0
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

CompletionRegistrationOptionsCompletionItem :: struct {
	// The server has support for completion item label
	// details (see also `CompletionItemLabelDetails`) when
	// receiving a completion item in a resolve call.
	// 
	// @since 3.17.0
	label_details_support: Maybe(bool) `json:"labelDetailsSupport,omitempty"`,
}

CodeActionDisabled :: struct {
	// Human readable description of why the code action is currently disabled.
	// 
	// This is displayed in the code actions UI.
	reason: string `json:"reason"`,
}

WorkspaceSymbolLocationVariant1 :: struct {
	uri: DocumentUri `json:"uri"`,
}

SemanticTokensOptionsRangeVariant1 :: struct {

}

SemanticTokensOptionsFullVariant1 :: struct {
	// The server supports deltas for full documents.
	delta: Maybe(bool) `json:"delta,omitempty"`,
}

NotebookDocumentChangeEventCellsStructure :: struct {
	// The change to the cell array.
	array: NotebookCellArrayChange `json:"array"`,
	// Additional opened cell text documents.
	did_open: Maybe([]TextDocumentItem) `json:"didOpen,omitempty"`,
	// Additional closed cell text documents.
	did_close: Maybe([]TextDocumentIdentifier) `json:"didClose,omitempty"`,
}

NotebookDocumentChangeEventCellsTextContentItem :: struct {
	document: VersionedTextDocumentIdentifier `json:"document"`,
	changes: []TextDocumentContentChangeEvent `json:"changes"`,
}

NotebookDocumentChangeEventCells :: struct {
	// Changes to the cell structure to add or
	// remove cells.
	structure: Maybe(NotebookDocumentChangeEventCellsStructure) `json:"structure,omitempty"`,
	// Changes to notebook cells properties like its
	// kind, execution summary or metadata.
	data: Maybe([]NotebookCell) `json:"data,omitempty"`,
	// Changes to the text content of notebook cells.
	text_content: Maybe([]NotebookDocumentChangeEventCellsTextContentItem) `json:"textContent,omitempty"`,
}

_InitializeParamsClientInfo :: struct {
	// The name of the client as defined by the client.
	name: string `json:"name"`,
	// The client's version as defined by the client.
	version: Maybe(string) `json:"version,omitempty"`,
}

ServerCapabilitiesWorkspace :: struct {
	// The server supports workspace folder.
	// 
	// @since 3.6.0
	workspace_folders: Maybe(WorkspaceFoldersServerCapabilities) `json:"workspaceFolders,omitempty"`,
	// The server is interested in notifications/requests for operations on files.
	// 
	// @since 3.16.0
	file_operations: Maybe(FileOperationOptions) `json:"fileOperations,omitempty"`,
}

CompletionOptionsCompletionItem :: struct {
	// The server has support for completion item label
	// details (see also `CompletionItemLabelDetails`) when
	// receiving a completion item in a resolve call.
	// 
	// @since 3.17.0
	label_details_support: Maybe(bool) `json:"labelDetailsSupport,omitempty"`,
}

NotebookDocumentSyncOptionsNotebookSelectorItemVariant0CellsItem :: struct {
	language: string `json:"language"`,
}

NotebookDocumentSyncOptionsNotebookSelectorItemVariant0 :: struct {
	// The notebook to be synced If a string
	// value is provided it matches against the
	// notebook type. '*' matches every notebook.
	notebook: union {string, NotebookDocumentFilter} `json:"notebook"`,
	// The cells of the matching notebook to be synced.
	cells: Maybe([]NotebookDocumentSyncOptionsNotebookSelectorItemVariant0CellsItem) `json:"cells,omitempty"`,
}

NotebookDocumentSyncOptionsNotebookSelectorItemVariant1CellsItem :: struct {
	language: string `json:"language"`,
}

NotebookDocumentSyncOptionsNotebookSelectorItemVariant1 :: struct {
	// The notebook to be synced If a string
	// value is provided it matches against the
	// notebook type. '*' matches every notebook.
	notebook: Maybe(union {string, NotebookDocumentFilter}) `json:"notebook,omitempty"`,
	// The cells of the matching notebook to be synced.
	cells: []NotebookDocumentSyncOptionsNotebookSelectorItemVariant1CellsItem `json:"cells"`,
}

NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant0CellsItem :: struct {
	language: string `json:"language"`,
}

NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant0 :: struct {
	// The notebook to be synced If a string
	// value is provided it matches against the
	// notebook type. '*' matches every notebook.
	notebook: union {string, NotebookDocumentFilter} `json:"notebook"`,
	// The cells of the matching notebook to be synced.
	cells: Maybe([]NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant0CellsItem) `json:"cells,omitempty"`,
}

NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant1CellsItem :: struct {
	language: string `json:"language"`,
}

NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant1 :: struct {
	// The notebook to be synced If a string
	// value is provided it matches against the
	// notebook type. '*' matches every notebook.
	notebook: Maybe(union {string, NotebookDocumentFilter}) `json:"notebook,omitempty"`,
	// The cells of the matching notebook to be synced.
	cells: []NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant1CellsItem `json:"cells"`,
}

GeneralClientCapabilitiesStaleRequestSupport :: struct {
	// The client will actively cancel the request.
	cancel: bool `json:"cancel"`,
	// The list of requests for which the client
	// will retry the request if it receives a
	// response with error code `ContentModified`
	retry_on_content_modified: []string `json:"retryOnContentModified"`,
}

WorkspaceEditClientCapabilitiesChangeAnnotationSupport :: struct {
	// Whether the client groups edits with equal labels into tree nodes,
	// for instance all edits labelled with "Changes in Strings" would
	// be a tree node.
	groups_on_label: Maybe(bool) `json:"groupsOnLabel,omitempty"`,
}

WorkspaceSymbolClientCapabilitiesSymbolKind :: struct {
	// The symbol kind values the client supports. When this
	// property exists the client also guarantees that it will
	// handle values outside its set gracefully and falls back
	// to a default value when unknown.
	// 
	// If this property is not present the client only supports
	// the symbol kinds from `File` to `Array` as defined in
	// the initial version of the protocol.
	value_set: Maybe([]SymbolKind) `json:"valueSet,omitempty"`,
}

WorkspaceSymbolClientCapabilitiesTagSupport :: struct {
	// The tags supported by the client.
	value_set: []SymbolTag `json:"valueSet"`,
}

WorkspaceSymbolClientCapabilitiesResolveSupport :: struct {
	// The properties that a client can resolve lazily. Usually
	// `location.range`
	properties: []string `json:"properties"`,
}

CompletionClientCapabilitiesCompletionItemTagSupport :: struct {
	// The tags supported by the client.
	value_set: []CompletionItemTag `json:"valueSet"`,
}

CompletionClientCapabilitiesCompletionItemResolveSupport :: struct {
	// The properties that a client can resolve lazily.
	properties: []string `json:"properties"`,
}

CompletionClientCapabilitiesCompletionItemInsertTextModeSupport :: struct {
	value_set: []InsertTextMode `json:"valueSet"`,
}

CompletionClientCapabilitiesCompletionItem :: struct {
	// Client supports snippets as insert text.
	// 
	// A snippet can define tab stops and placeholders with `$1`, `$2`
	// and `${3:foo}`. `$0` defines the final tab stop, it defaults to
	// the end of the snippet. Placeholders with equal identifiers are linked,
	// that is typing in one will update others too.
	snippet_support: Maybe(bool) `json:"snippetSupport,omitempty"`,
	// Client supports commit characters on a completion item.
	commit_characters_support: Maybe(bool) `json:"commitCharactersSupport,omitempty"`,
	// Client supports the following content formats for the documentation
	// property. The order describes the preferred format of the client.
	documentation_format: Maybe([]MarkupKind) `json:"documentationFormat,omitempty"`,
	// Client supports the deprecated property on a completion item.
	deprecated_support: Maybe(bool) `json:"deprecatedSupport,omitempty"`,
	// Client supports the preselect property on a completion item.
	preselect_support: Maybe(bool) `json:"preselectSupport,omitempty"`,
	// Client supports the tag property on a completion item. Clients supporting
	// tags have to handle unknown tags gracefully. Clients especially need to
	// preserve unknown tags when sending a completion item back to the server in
	// a resolve call.
	// 
	// @since 3.15.0
	tag_support: Maybe(CompletionClientCapabilitiesCompletionItemTagSupport) `json:"tagSupport,omitempty"`,
	// Client support insert replace edit to control different behavior if a
	// completion item is inserted in the text or should replace text.
	// 
	// @since 3.16.0
	insert_replace_support: Maybe(bool) `json:"insertReplaceSupport,omitempty"`,
	// Indicates which properties a client can resolve lazily on a completion
	// item. Before version 3.16.0 only the predefined properties `documentation`
	// and `details` could be resolved lazily.
	// 
	// @since 3.16.0
	resolve_support: Maybe(CompletionClientCapabilitiesCompletionItemResolveSupport) `json:"resolveSupport,omitempty"`,
	// The client supports the `insertTextMode` property on
	// a completion item to override the whitespace handling mode
	// as defined by the client (see `insertTextMode`).
	// 
	// @since 3.16.0
	insert_text_mode_support: Maybe(CompletionClientCapabilitiesCompletionItemInsertTextModeSupport) `json:"insertTextModeSupport,omitempty"`,
	// The client has support for completion item label
	// details (see also `CompletionItemLabelDetails`).
	// 
	// @since 3.17.0
	label_details_support: Maybe(bool) `json:"labelDetailsSupport,omitempty"`,
}

CompletionClientCapabilitiesCompletionItemKind :: struct {
	// The completion item kind values the client supports. When this
	// property exists the client also guarantees that it will
	// handle values outside its set gracefully and falls back
	// to a default value when unknown.
	// 
	// If this property is not present the client only supports
	// the completion items kinds from `Text` to `Reference` as defined in
	// the initial version of the protocol.
	value_set: Maybe([]CompletionItemKind) `json:"valueSet,omitempty"`,
}

CompletionClientCapabilitiesCompletionList :: struct {
	// The client supports the following itemDefaults on
	// a completion list.
	// 
	// The value lists the supported property names of the
	// `CompletionList.itemDefaults` object. If omitted
	// no properties are supported.
	// 
	// @since 3.17.0
	item_defaults: Maybe([]string) `json:"itemDefaults,omitempty"`,
}

SignatureHelpClientCapabilitiesSignatureInformationParameterInformation :: struct {
	// The client supports processing label offsets instead of a
	// simple label string.
	// 
	// @since 3.14.0
	label_offset_support: Maybe(bool) `json:"labelOffsetSupport,omitempty"`,
}

SignatureHelpClientCapabilitiesSignatureInformation :: struct {
	// Client supports the following content formats for the documentation
	// property. The order describes the preferred format of the client.
	documentation_format: Maybe([]MarkupKind) `json:"documentationFormat,omitempty"`,
	// Client capabilities specific to parameter information.
	parameter_information: Maybe(SignatureHelpClientCapabilitiesSignatureInformationParameterInformation) `json:"parameterInformation,omitempty"`,
	// The client supports the `activeParameter` property on `SignatureInformation`
	// literal.
	// 
	// @since 3.16.0
	active_parameter_support: Maybe(bool) `json:"activeParameterSupport,omitempty"`,
}

DocumentSymbolClientCapabilitiesSymbolKind :: struct {
	// The symbol kind values the client supports. When this
	// property exists the client also guarantees that it will
	// handle values outside its set gracefully and falls back
	// to a default value when unknown.
	// 
	// If this property is not present the client only supports
	// the symbol kinds from `File` to `Array` as defined in
	// the initial version of the protocol.
	value_set: Maybe([]SymbolKind) `json:"valueSet,omitempty"`,
}

DocumentSymbolClientCapabilitiesTagSupport :: struct {
	// The tags supported by the client.
	value_set: []SymbolTag `json:"valueSet"`,
}

CodeActionClientCapabilitiesCodeActionLiteralSupportCodeActionKind :: struct {
	// The code action kind values the client supports. When this
	// property exists the client also guarantees that it will
	// handle values outside its set gracefully and falls back
	// to a default value when unknown.
	value_set: []CodeActionKind `json:"valueSet"`,
}

CodeActionClientCapabilitiesCodeActionLiteralSupport :: struct {
	// The code action kind is support with the following value
	// set.
	code_action_kind: CodeActionClientCapabilitiesCodeActionLiteralSupportCodeActionKind `json:"codeActionKind"`,
}

CodeActionClientCapabilitiesResolveSupport :: struct {
	// The properties that a client can resolve lazily.
	properties: []string `json:"properties"`,
}

FoldingRangeClientCapabilitiesFoldingRangeKind :: struct {
	// The folding range kind values the client supports. When this
	// property exists the client also guarantees that it will
	// handle values outside its set gracefully and falls back
	// to a default value when unknown.
	value_set: Maybe([]FoldingRangeKind) `json:"valueSet,omitempty"`,
}

FoldingRangeClientCapabilitiesFoldingRange :: struct {
	// If set, the client signals that it supports setting collapsedText on
	// folding ranges to display custom labels instead of the default text.
	// 
	// @since 3.17.0
	collapsed_text: Maybe(bool) `json:"collapsedText,omitempty"`,
}

PublishDiagnosticsClientCapabilitiesTagSupport :: struct {
	// The tags supported by the client.
	value_set: []DiagnosticTag `json:"valueSet"`,
}

SemanticTokensClientCapabilitiesRequestsRangeVariant1 :: struct {

}

SemanticTokensClientCapabilitiesRequestsFullVariant1 :: struct {
	// The client will send the `textDocument/semanticTokens/full/delta` request if
	// the server provides a corresponding handler.
	delta: Maybe(bool) `json:"delta,omitempty"`,
}

SemanticTokensClientCapabilitiesRequests :: struct {
	// The client will send the `textDocument/semanticTokens/range` request if
	// the server provides a corresponding handler.
	range: Maybe(union {bool, SemanticTokensClientCapabilitiesRequestsRangeVariant1}) `json:"range,omitempty"`,
	// The client will send the `textDocument/semanticTokens/full` request if
	// the server provides a corresponding handler.
	full: Maybe(union {bool, SemanticTokensClientCapabilitiesRequestsFullVariant1}) `json:"full,omitempty"`,
}

InlayHintClientCapabilitiesResolveSupport :: struct {
	// The properties that a client can resolve lazily.
	properties: []string `json:"properties"`,
}

ShowMessageRequestClientCapabilitiesMessageActionItem :: struct {
	// Whether the client supports additional attributes which
	// are preserved and send back to the server in the
	// request's response.
	additional_properties_support: Maybe(bool) `json:"additionalPropertiesSupport,omitempty"`,
}

PrepareRenameResultVariant1 :: struct {
	range: Range `json:"range"`,
	placeholder: string `json:"placeholder"`,
}

PrepareRenameResultVariant2 :: struct {
	default_behavior: bool `json:"defaultBehavior"`,
}

TextDocumentContentChangeEventVariant0 :: struct {
	// The range of the document that changed.
	range: Range `json:"range"`,
	// The optional length of the range that got replaced.
	// 
	// @deprecated use range instead.
	range_length: Maybe(u32) `json:"rangeLength,omitempty"`,
	// The new text for the provided range.
	text: string `json:"text"`,
}

TextDocumentContentChangeEventVariant1 :: struct {
	// The new text of the whole document.
	text: string `json:"text"`,
}

MarkedStringVariant1 :: struct {
	language: string `json:"language"`,
	value: string `json:"value"`,
}

TextDocumentFilterVariant0 :: struct {
	// A language id, like `typescript`.
	language: string `json:"language"`,
	// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	scheme: Maybe(string) `json:"scheme,omitempty"`,
	// A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
	pattern: Maybe(string) `json:"pattern,omitempty"`,
}

TextDocumentFilterVariant1 :: struct {
	// A language id, like `typescript`.
	language: Maybe(string) `json:"language,omitempty"`,
	// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	scheme: string `json:"scheme"`,
	// A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
	pattern: Maybe(string) `json:"pattern,omitempty"`,
}

TextDocumentFilterVariant2 :: struct {
	// A language id, like `typescript`.
	language: Maybe(string) `json:"language,omitempty"`,
	// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	scheme: Maybe(string) `json:"scheme,omitempty"`,
	// A glob pattern, like **​/*.{ts,js}. See TextDocumentFilter for examples.
	pattern: string `json:"pattern"`,
}

NotebookDocumentFilterVariant0 :: struct {
	// The type of the enclosing notebook.
	notebook_type: string `json:"notebookType"`,
	// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	scheme: Maybe(string) `json:"scheme,omitempty"`,
	// A glob pattern.
	pattern: Maybe(string) `json:"pattern,omitempty"`,
}

NotebookDocumentFilterVariant1 :: struct {
	// The type of the enclosing notebook.
	notebook_type: Maybe(string) `json:"notebookType,omitempty"`,
	// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	scheme: string `json:"scheme"`,
	// A glob pattern.
	pattern: Maybe(string) `json:"pattern,omitempty"`,
}

NotebookDocumentFilterVariant2 :: struct {
	// The type of the enclosing notebook.
	notebook_type: Maybe(string) `json:"notebookType,omitempty"`,
	// A Uri {@link Uri.scheme scheme}, like `file` or `untitled`.
	scheme: Maybe(string) `json:"scheme,omitempty"`,
	// A glob pattern.
	pattern: string `json:"pattern"`,
}

// Structures

ImplementationParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
}

// Represents a location inside a resource, such as a line
// inside a text file.
Location :: struct {
	uri: DocumentUri `json:"uri"`,
	range: Range `json:"range"`,
}

ImplementationRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

TypeDefinitionParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
}

TypeDefinitionRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// A workspace folder inside a client.
WorkspaceFolder :: struct {
	// The associated URI for this workspace folder.
	uri: URI `json:"uri"`,
	// The name of the workspace folder. Used to refer to this
	// workspace folder in the user interface.
	name: string `json:"name"`,
}

// The parameters of a `workspace/didChangeWorkspaceFolders` notification.
DidChangeWorkspaceFoldersParams :: struct {
	// The actual workspace folder change event.
	event: WorkspaceFoldersChangeEvent `json:"event"`,
}

// The parameters of a configuration request.
ConfigurationParams :: struct {
	items: []ConfigurationItem `json:"items"`,
}

// Parameters for a {@link DocumentColorRequest}.
DocumentColorParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
}

// Represents a color range from a document.
ColorInformation :: struct {
	// The range in the document where this color appears.
	range: Range `json:"range"`,
	// The actual color value for this color range.
	color: Color `json:"color"`,
}

DocumentColorRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// Parameters for a {@link ColorPresentationRequest}.
ColorPresentationParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The color to request presentations for.
	color: Color `json:"color"`,
	// The range where the color would be inserted. Serves as a context.
	range: Range `json:"range"`,
}

ColorPresentation :: struct {
	// The label of this color presentation. It will be shown on the color
	// picker header. By default this is also the text that is inserted when selecting
	// this color presentation.
	label: string `json:"label"`,
	// An {@link TextEdit edit} which is applied to a document when selecting
	// this presentation for the color.  When `falsy` the {@link ColorPresentation.label label}
	// is used.
	text_edit: Maybe(TextEdit) `json:"textEdit,omitempty"`,
	// An optional array of additional {@link TextEdit text edits} that are applied when
	// selecting this color presentation. Edits must not overlap with the main {@link ColorPresentation.textEdit edit} nor with themselves.
	additional_text_edits: Maybe([]TextEdit) `json:"additionalTextEdits,omitempty"`,
}

WorkDoneProgressOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// General text document registration options.
TextDocumentRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
}

// Parameters for a {@link FoldingRangeRequest}.
FoldingRangeParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
}

// Represents a folding range. To be valid, start and end line must be bigger than zero and smaller
// than the number of lines in the document. Clients are free to ignore invalid ranges.
FoldingRange :: struct {
	// The zero-based start line of the range to fold. The folded area starts after the line's last character.
	// To be valid, the end must be zero or larger and smaller than the number of lines in the document.
	start_line: u32 `json:"startLine"`,
	// The zero-based character offset from where the folded range starts. If not defined, defaults to the length of the start line.
	start_character: Maybe(u32) `json:"startCharacter,omitempty"`,
	// The zero-based end line of the range to fold. The folded area ends with the line's last character.
	// To be valid, the end must be zero or larger and smaller than the number of lines in the document.
	end_line: u32 `json:"endLine"`,
	// The zero-based character offset before the folded range ends. If not defined, defaults to the length of the end line.
	end_character: Maybe(u32) `json:"endCharacter,omitempty"`,
	// Describes the kind of the folding range such as `comment' or 'region'. The kind
	// is used to categorize folding ranges and used by commands like 'Fold all comments'.
	// See {@link FoldingRangeKind} for an enumeration of standardized kinds.
	kind: Maybe(FoldingRangeKind) `json:"kind,omitempty"`,
	// The text that the client should show when the specified range is
	// collapsed. If not defined or not supported by the client, a default
	// will be chosen by the client.
	// 
	// @since 3.17.0
	collapsed_text: Maybe(string) `json:"collapsedText,omitempty"`,
}

FoldingRangeRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

DeclarationParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
}

DeclarationRegistrationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// A parameter literal used in selection range requests.
SelectionRangeParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The positions inside the text document.
	positions: []Position `json:"positions"`,
}

// A selection range represents a part of a selection hierarchy. A selection range
// may have a parent selection range that contains it.
SelectionRange :: struct {
	// The {@link Range range} of this selection range.
	range: Range `json:"range"`,
	// The parent selection range containing this range. Therefore `parent.range` must contain `this.range`.
	parent: ^SelectionRange `json:"parent,omitempty"`,
}

SelectionRangeRegistrationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

WorkDoneProgressCreateParams :: struct {
	// The token to be used to report progress.
	token: ProgressToken `json:"token"`,
}

WorkDoneProgressCancelParams :: struct {
	// The token to be used to report progress.
	token: ProgressToken `json:"token"`,
}

// The parameter of a `textDocument/prepareCallHierarchy` request.
// 
// @since 3.16.0
CallHierarchyPrepareParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
}

// Represents programming constructs like functions or constructors in the context
// of call hierarchy.
// 
// @since 3.16.0
CallHierarchyItem :: struct {
	// The name of this item.
	name: string `json:"name"`,
	// The kind of this item.
	kind: SymbolKind `json:"kind"`,
	// Tags for this item.
	tags: Maybe([]SymbolTag) `json:"tags,omitempty"`,
	// More detail for this item, e.g. the signature of a function.
	detail: Maybe(string) `json:"detail,omitempty"`,
	// The resource identifier of this item.
	uri: DocumentUri `json:"uri"`,
	// The range enclosing this symbol not including leading/trailing whitespace but everything else, e.g. comments and code.
	range: Range `json:"range"`,
	// The range that should be selected and revealed when this symbol is being picked, e.g. the name of a function.
	// Must be contained by the {@link CallHierarchyItem.range `range`}.
	selection_range: Range `json:"selectionRange"`,
	// A data entry field that is preserved between a call hierarchy prepare and
	// incoming calls or outgoing calls requests.
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Call hierarchy options used during static or dynamic registration.
// 
// @since 3.16.0
CallHierarchyRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// The parameter of a `callHierarchy/incomingCalls` request.
// 
// @since 3.16.0
CallHierarchyIncomingCallsParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	item: CallHierarchyItem `json:"item"`,
}

// Represents an incoming call, e.g. a caller of a method or constructor.
// 
// @since 3.16.0
CallHierarchyIncomingCall :: struct {
	// The item that makes the call.
	from: CallHierarchyItem `json:"from"`,
	// The ranges at which the calls appear. This is relative to the caller
	// denoted by {@link CallHierarchyIncomingCall.from `this.from`}.
	from_ranges: []Range `json:"fromRanges"`,
}

// The parameter of a `callHierarchy/outgoingCalls` request.
// 
// @since 3.16.0
CallHierarchyOutgoingCallsParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	item: CallHierarchyItem `json:"item"`,
}

// Represents an outgoing call, e.g. calling a getter from a method or a method from a constructor etc.
// 
// @since 3.16.0
CallHierarchyOutgoingCall :: struct {
	// The item that is called.
	to: CallHierarchyItem `json:"to"`,
	// The range at which this item is called. This is the range relative to the caller, e.g the item
	// passed to {@link CallHierarchyItemProvider.provideCallHierarchyOutgoingCalls `provideCallHierarchyOutgoingCalls`}
	// and not {@link CallHierarchyOutgoingCall.to `this.to`}.
	from_ranges: []Range `json:"fromRanges"`,
}

// @since 3.16.0
SemanticTokensParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
}

// @since 3.16.0
SemanticTokens :: struct {
	// An optional result id. If provided and clients support delta updating
	// the client will include the result id in the next semantic token request.
	// A server can then instead of computing all semantic tokens again simply
	// send a delta.
	result_id: Maybe(string) `json:"resultId,omitempty"`,
	// The actual tokens.
	data: []u32 `json:"data"`,
}

// @since 3.16.0
SemanticTokensPartialResult :: struct {
	data: []u32 `json:"data"`,
}

// @since 3.16.0
SemanticTokensRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The legend used by the server
	legend: SemanticTokensLegend `json:"legend"`,
	// Server supports providing semantic tokens for a specific range
	// of a document.
	range: Maybe(union {bool, SemanticTokensRegistrationOptionsRangeVariant1}) `json:"range,omitempty"`,
	// Server supports providing semantic tokens for a full document.
	full: Maybe(union {bool, SemanticTokensRegistrationOptionsFullVariant1}) `json:"full,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// @since 3.16.0
SemanticTokensDeltaParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The result id of a previous response. The result Id can either point to a full response
	// or a delta response depending on what was received last.
	previous_result_id: string `json:"previousResultId"`,
}

// @since 3.16.0
SemanticTokensDelta :: struct {
	result_id: Maybe(string) `json:"resultId,omitempty"`,
	// The semantic token edits to transform a previous result into a new result.
	edits: []SemanticTokensEdit `json:"edits"`,
}

// @since 3.16.0
SemanticTokensDeltaPartialResult :: struct {
	edits: []SemanticTokensEdit `json:"edits"`,
}

// @since 3.16.0
SemanticTokensRangeParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The range the semantic tokens are requested for.
	range: Range `json:"range"`,
}

// Params to show a resource in the UI.
// 
// @since 3.16.0
ShowDocumentParams :: struct {
	// The uri to show.
	uri: URI `json:"uri"`,
	// Indicates to show the resource in an external program.
	// To show, for example, `https://code.visualstudio.com/`
	// in the default WEB browser set `external` to `true`.
	external: Maybe(bool) `json:"external,omitempty"`,
	// An optional property to indicate whether the editor
	// showing the document should take focus or not.
	// Clients might ignore this property if an external
	// program is started.
	take_focus: Maybe(bool) `json:"takeFocus,omitempty"`,
	// An optional selection range if the document is a text
	// document. Clients might ignore the property if an
	// external program is started or the file is not a text
	// file.
	selection: Maybe(Range) `json:"selection,omitempty"`,
}

// The result of a showDocument request.
// 
// @since 3.16.0
ShowDocumentResult :: struct {
	// A boolean indicating if the show was successful.
	success: bool `json:"success"`,
}

LinkedEditingRangeParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
}

// The result of a linked editing range request.
// 
// @since 3.16.0
LinkedEditingRanges :: struct {
	// A list of ranges that can be edited together. The ranges must have
	// identical length and contain identical text content. The ranges cannot overlap.
	ranges: []Range `json:"ranges"`,
	// An optional word pattern (regular expression) that describes valid contents for
	// the given ranges. If no pattern is provided, the client configuration's word
	// pattern will be used.
	word_pattern: Maybe(string) `json:"wordPattern,omitempty"`,
}

LinkedEditingRangeRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// The parameters sent in notifications/requests for user-initiated creation of
// files.
// 
// @since 3.16.0
CreateFilesParams :: struct {
	// An array of all files/folders created in this operation.
	files: []FileCreate `json:"files"`,
}

// A workspace edit represents changes to many resources managed in the workspace. The edit
// should either provide `changes` or `documentChanges`. If documentChanges are present
// they are preferred over `changes` if the client can handle versioned document edits.
// 
// Since version 3.13.0 a workspace edit can contain resource operations as well. If resource
// operations are present clients need to execute the operations in the order in which they
// are provided. So a workspace edit for example can consist of the following two changes:
// (1) a create file a.txt and (2) a text document edit which insert text into file a.txt.
// 
// An invalid sequence (e.g. (1) delete file a.txt and (2) insert text into file a.txt) will
// cause failure of the operation. How the client recovers from the failure is described by
// the client capability: `workspace.workspaceEdit.failureHandling`
WorkspaceEdit :: struct {
	// Holds changes to existing resources.
	changes: Maybe(map[DocumentUri][]TextEdit) `json:"changes,omitempty"`,
	// Depending on the client capability `workspace.workspaceEdit.resourceOperations` document changes
	// are either an array of `TextDocumentEdit`s to express changes to n different text documents
	// where each text document edit addresses a specific version of a text document. Or it can contain
	// above `TextDocumentEdit`s mixed with create, rename and delete file / folder operations.
	// 
	// Whether a client supports versioned document edits is expressed via
	// `workspace.workspaceEdit.documentChanges` client capability.
	// 
	// If a client neither supports `documentChanges` nor `workspace.workspaceEdit.resourceOperations` then
	// only plain `TextEdit`s using the `changes` property are supported.
	document_changes: Maybe([]union {TextDocumentEdit, CreateFile, RenameFile, DeleteFile}) `json:"documentChanges,omitempty"`,
	// A map of change annotations that can be referenced in `AnnotatedTextEdit`s or create, rename and
	// delete file / folder operations.
	// 
	// Whether clients honor this property depends on the client capability `workspace.changeAnnotationSupport`.
	// 
	// @since 3.16.0
	change_annotations: Maybe(map[ChangeAnnotationIdentifier]ChangeAnnotation) `json:"changeAnnotations,omitempty"`,
}

// The options to register for file operations.
// 
// @since 3.16.0
FileOperationRegistrationOptions :: struct {
	// The actual filters.
	filters: []FileOperationFilter `json:"filters"`,
}

// The parameters sent in notifications/requests for user-initiated renames of
// files.
// 
// @since 3.16.0
RenameFilesParams :: struct {
	// An array of all files/folders renamed in this operation. When a folder is renamed, only
	// the folder will be included, and not its children.
	files: []FileRename `json:"files"`,
}

// The parameters sent in notifications/requests for user-initiated deletes of
// files.
// 
// @since 3.16.0
DeleteFilesParams :: struct {
	// An array of all files/folders deleted in this operation.
	files: []FileDelete `json:"files"`,
}

MonikerParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
}

// Moniker definition to match LSIF 0.5 moniker definition.
// 
// @since 3.16.0
Moniker :: struct {
	// The scheme of the moniker. For example tsc or .Net
	scheme: string `json:"scheme"`,
	// The identifier of the moniker. The value is opaque in LSIF however
	// schema owners are allowed to define the structure if they want.
	identifier: string `json:"identifier"`,
	// The scope in which the moniker is unique
	unique: UniquenessLevel `json:"unique"`,
	// The moniker kind if known.
	kind: Maybe(MonikerKind) `json:"kind,omitempty"`,
}

MonikerRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// The parameter of a `textDocument/prepareTypeHierarchy` request.
// 
// @since 3.17.0
TypeHierarchyPrepareParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
}

// @since 3.17.0
TypeHierarchyItem :: struct {
	// The name of this item.
	name: string `json:"name"`,
	// The kind of this item.
	kind: SymbolKind `json:"kind"`,
	// Tags for this item.
	tags: Maybe([]SymbolTag) `json:"tags,omitempty"`,
	// More detail for this item, e.g. the signature of a function.
	detail: Maybe(string) `json:"detail,omitempty"`,
	// The resource identifier of this item.
	uri: DocumentUri `json:"uri"`,
	// The range enclosing this symbol not including leading/trailing whitespace
	// but everything else, e.g. comments and code.
	range: Range `json:"range"`,
	// The range that should be selected and revealed when this symbol is being
	// picked, e.g. the name of a function. Must be contained by the
	// {@link TypeHierarchyItem.range `range`}.
	selection_range: Range `json:"selectionRange"`,
	// A data entry field that is preserved between a type hierarchy prepare and
	// supertypes or subtypes requests. It could also be used to identify the
	// type hierarchy in the server, helping improve the performance on
	// resolving supertypes and subtypes.
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Type hierarchy options used during static or dynamic registration.
// 
// @since 3.17.0
TypeHierarchyRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// The parameter of a `typeHierarchy/supertypes` request.
// 
// @since 3.17.0
TypeHierarchySupertypesParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	item: TypeHierarchyItem `json:"item"`,
}

// The parameter of a `typeHierarchy/subtypes` request.
// 
// @since 3.17.0
TypeHierarchySubtypesParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	item: TypeHierarchyItem `json:"item"`,
}

// A parameter literal used in inline value requests.
// 
// @since 3.17.0
InlineValueParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The document range for which inline values should be computed.
	range: Range `json:"range"`,
	// Additional information about the context in which inline values were
	// requested.
	context_: InlineValueContext `json:"context"`,
}

// Inline value options used during static or dynamic registration.
// 
// @since 3.17.0
InlineValueRegistrationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// A parameter literal used in inlay hint requests.
// 
// @since 3.17.0
InlayHintParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The document range for which inlay hints should be computed.
	range: Range `json:"range"`,
}

// Inlay hint information.
// 
// @since 3.17.0
InlayHint :: struct {
	// The position of this hint.
	// 
	// If multiple hints have the same position, they will be shown in the order
	// they appear in the response.
	position: Position `json:"position"`,
	// The label of this hint. A human readable string or an array of
	// InlayHintLabelPart label parts.
	// 
	// *Note* that neither the string nor the label part can be empty.
	label: union {string, []InlayHintLabelPart} `json:"label"`,
	// The kind of this hint. Can be omitted in which case the client
	// should fall back to a reasonable default.
	kind: Maybe(InlayHintKind) `json:"kind,omitempty"`,
	// Optional text edits that are performed when accepting this inlay hint.
	// 
	// *Note* that edits are expected to change the document so that the inlay
	// hint (or its nearest variant) is now part of the document and the inlay
	// hint itself is now obsolete.
	text_edits: Maybe([]TextEdit) `json:"textEdits,omitempty"`,
	// The tooltip text when you hover over this item.
	tooltip: Maybe(union {string, MarkupContent}) `json:"tooltip,omitempty"`,
	// Render padding before the hint.
	// 
	// Note: Padding should use the editor's background color, not the
	// background color of the hint itself. That means padding can be used
	// to visually align/separate an inlay hint.
	padding_left: Maybe(bool) `json:"paddingLeft,omitempty"`,
	// Render padding after the hint.
	// 
	// Note: Padding should use the editor's background color, not the
	// background color of the hint itself. That means padding can be used
	// to visually align/separate an inlay hint.
	padding_right: Maybe(bool) `json:"paddingRight,omitempty"`,
	// A data entry field that is preserved on an inlay hint between
	// a `textDocument/inlayHint` and a `inlayHint/resolve` request.
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Inlay hint options used during static or dynamic registration.
// 
// @since 3.17.0
InlayHintRegistrationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The server provides support to resolve additional
	// information for an inlay hint item.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// Parameters of the document diagnostic request.
// 
// @since 3.17.0
DocumentDiagnosticParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The additional identifier  provided during registration.
	identifier: Maybe(string) `json:"identifier,omitempty"`,
	// The result id of a previous response if provided.
	previous_result_id: Maybe(string) `json:"previousResultId,omitempty"`,
}

// A partial result for a document diagnostic report.
// 
// @since 3.17.0
DocumentDiagnosticReportPartialResult :: struct {
	related_documents: map[DocumentUri]union {FullDocumentDiagnosticReport, UnchangedDocumentDiagnosticReport} `json:"relatedDocuments"`,
}

// Cancellation data returned from a diagnostic request.
// 
// @since 3.17.0
DiagnosticServerCancellationData :: struct {
	retrigger_request: bool `json:"retriggerRequest"`,
}

// Diagnostic registration options.
// 
// @since 3.17.0
DiagnosticRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// An optional identifier under which the diagnostics are
	// managed by the client.
	identifier: Maybe(string) `json:"identifier,omitempty"`,
	// Whether the language has inter file dependencies meaning that
	// editing code in one file can result in a different diagnostic
	// set in another file. Inter file dependencies are common for
	// most programming languages and typically uncommon for linters.
	inter_file_dependencies: bool `json:"interFileDependencies"`,
	// The server provides support for workspace diagnostics as well.
	workspace_diagnostics: bool `json:"workspaceDiagnostics"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

// Parameters of the workspace diagnostic request.
// 
// @since 3.17.0
WorkspaceDiagnosticParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The additional identifier provided during registration.
	identifier: Maybe(string) `json:"identifier,omitempty"`,
	// The currently known diagnostic reports with their
	// previous result ids.
	previous_result_ids: []PreviousResultId `json:"previousResultIds"`,
}

// A workspace diagnostic report.
// 
// @since 3.17.0
WorkspaceDiagnosticReport :: struct {
	items: []WorkspaceDocumentDiagnosticReport `json:"items"`,
}

// A partial result for a workspace diagnostic report.
// 
// @since 3.17.0
WorkspaceDiagnosticReportPartialResult :: struct {
	items: []WorkspaceDocumentDiagnosticReport `json:"items"`,
}

// The params sent in an open notebook document notification.
// 
// @since 3.17.0
DidOpenNotebookDocumentParams :: struct {
	// The notebook document that got opened.
	notebook_document: NotebookDocument `json:"notebookDocument"`,
	// The text documents that represent the content
	// of a notebook cell.
	cell_text_documents: []TextDocumentItem `json:"cellTextDocuments"`,
}

// The params sent in a change notebook document notification.
// 
// @since 3.17.0
DidChangeNotebookDocumentParams :: struct {
	// The notebook document that did change. The version number points
	// to the version after all provided changes have been applied. If
	// only the text document content of a cell changes the notebook version
	// doesn't necessarily have to change.
	notebook_document: VersionedNotebookDocumentIdentifier `json:"notebookDocument"`,
	// The actual changes to the notebook document.
	// 
	// The changes describe single state changes to the notebook document.
	// So if there are two changes c1 (at array index 0) and c2 (at array
	// index 1) for a notebook in state S then c1 moves the notebook from
	// S to S' and c2 from S' to S''. So c1 is computed on the state S and
	// c2 is computed on the state S'.
	// 
	// To mirror the content of a notebook using change events use the following approach:
	// - start with the same initial content
	// - apply the 'notebookDocument/didChange' notifications in the order you receive them.
	// - apply the `NotebookChangeEvent`s in a single notification in the order
	//   you receive them.
	change: NotebookDocumentChangeEvent `json:"change"`,
}

// The params sent in a save notebook document notification.
// 
// @since 3.17.0
DidSaveNotebookDocumentParams :: struct {
	// The notebook document that got saved.
	notebook_document: NotebookDocumentIdentifier `json:"notebookDocument"`,
}

// The params sent in a close notebook document notification.
// 
// @since 3.17.0
DidCloseNotebookDocumentParams :: struct {
	// The notebook document that got closed.
	notebook_document: NotebookDocumentIdentifier `json:"notebookDocument"`,
	// The text documents that represent the content
	// of a notebook cell that got closed.
	cell_text_documents: []TextDocumentIdentifier `json:"cellTextDocuments"`,
}

// A parameter literal used in inline completion requests.
// 
// @since 3.18.0
// @proposed
InlineCompletionParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// Additional information about the context in which inline completions were
	// requested.
	context_: InlineCompletionContext `json:"context"`,
}

// Represents a collection of {@link InlineCompletionItem inline completion items} to be presented in the editor.
// 
// @since 3.18.0
// @proposed
InlineCompletionList :: struct {
	// The inline completion items
	items: []InlineCompletionItem `json:"items"`,
}

// An inline completion item represents a text snippet that is proposed inline to complete text that is being typed.
// 
// @since 3.18.0
// @proposed
InlineCompletionItem :: struct {
	// The text to replace the range with. Must be set.
	insert_text: union {string, StringValue} `json:"insertText"`,
	// A text that is used to decide if this inline completion should be shown. When `falsy` the {@link InlineCompletionItem.insertText} is used.
	filter_text: Maybe(string) `json:"filterText,omitempty"`,
	// The range to replace. Must begin and end on the same line.
	range: Maybe(Range) `json:"range,omitempty"`,
	// An optional {@link Command} that is executed *after* inserting this completion.
	command: Maybe(Command) `json:"command,omitempty"`,
}

// Inline completion options used during static or dynamic registration.
// 
// @since 3.18.0
// @proposed
InlineCompletionRegistrationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

RegistrationParams :: struct {
	registrations: []Registration `json:"registrations"`,
}

UnregistrationParams :: struct {
	unregisterations: []Unregistration `json:"unregisterations"`,
}

InitializeParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The process Id of the parent process that started
	// the server.
	// 
	// Is `null` if the process has not been started by another process.
	// If the parent process is not alive then the server should exit.
	process_id: Maybe(i32) `json:"processId,omitempty"`,
	// Information about the client
	// 
	// @since 3.15.0
	client_info: Maybe(InitializeParamsClientInfo) `json:"clientInfo,omitempty"`,
	// The locale the client is currently showing the user interface
	// in. This must not necessarily be the locale of the operating
	// system.
	// 
	// Uses IETF language tags as the value's syntax
	// (See https://en.wikipedia.org/wiki/IETF_language_tag)
	// 
	// @since 3.16.0
	locale: Maybe(string) `json:"locale,omitempty"`,
	// The rootPath of the workspace. Is null
	// if no folder is open.
	// 
	// @deprecated in favour of rootUri.
	root_path: Maybe(string) `json:"rootPath,omitempty"`,
	// The rootUri of the workspace. Is null if no
	// folder is open. If both `rootPath` and `rootUri` are set
	// `rootUri` wins.
	// 
	// @deprecated in favour of workspaceFolders.
	root_uri: Maybe(DocumentUri) `json:"rootUri,omitempty"`,
	// The capabilities provided by the client (editor or tool)
	capabilities: ClientCapabilities `json:"capabilities"`,
	// User provided initialization options.
	initialization_options: Maybe(LSPAny) `json:"initializationOptions,omitempty"`,
	// The initial trace setting. If omitted trace is disabled ('off').
	trace: Maybe(TraceValues) `json:"trace,omitempty"`,
	// The workspace folders configured in the client when the server starts.
	// 
	// This property is only available if the client supports workspace folders.
	// It can be `null` if the client supports workspace folders but none are
	// configured.
	// 
	// @since 3.6.0
	workspace_folders: Maybe([]WorkspaceFolder) `json:"workspaceFolders,omitempty"`,
}

// The result returned from an initialize request.
InitializeResult :: struct {
	// The capabilities the language server provides.
	capabilities: ServerCapabilities `json:"capabilities"`,
	// Information about the server.
	// 
	// @since 3.15.0
	server_info: Maybe(InitializeResultServerInfo) `json:"serverInfo,omitempty"`,
}

// The data type of the ResponseError if the
// initialize request fails.
InitializeError :: struct {
	// Indicates whether the client execute the following retry logic:
	// (1) show the message provided by the ResponseError to the user
	// (2) user selects retry or cancel
	// (3) if user selected retry the initialize method is sent again.
	retry: bool `json:"retry"`,
}

InitializedParams :: struct {
}

// The parameters of a change configuration notification.
DidChangeConfigurationParams :: struct {
	// The actual changed settings
	settings: LSPAny `json:"settings"`,
}

DidChangeConfigurationRegistrationOptions :: struct {
	section: Maybe(union {string, []string}) `json:"section,omitempty"`,
}

// The parameters of a notification message.
ShowMessageParams :: struct {
	// The message type. See {@link MessageType}
	type: MessageType `json:"type"`,
	// The actual message.
	message: string `json:"message"`,
}

ShowMessageRequestParams :: struct {
	// The message type. See {@link MessageType}
	type: MessageType `json:"type"`,
	// The actual message.
	message: string `json:"message"`,
	// The message action items to present.
	actions: Maybe([]MessageActionItem) `json:"actions,omitempty"`,
}

MessageActionItem :: struct {
	// A short title like 'Retry', 'Open Log' etc.
	title: string `json:"title"`,
}

// The log message parameters.
LogMessageParams :: struct {
	// The message type. See {@link MessageType}
	type: MessageType `json:"type"`,
	// The actual message.
	message: string `json:"message"`,
}

// The parameters sent in an open text document notification
DidOpenTextDocumentParams :: struct {
	// The document that was opened.
	text_document: TextDocumentItem `json:"textDocument"`,
}

// The change text document notification's parameters.
DidChangeTextDocumentParams :: struct {
	// The document that did change. The version number points
	// to the version after all provided content changes have
	// been applied.
	text_document: VersionedTextDocumentIdentifier `json:"textDocument"`,
	// The actual content changes. The content changes describe single state changes
	// to the document. So if there are two content changes c1 (at array index 0) and
	// c2 (at array index 1) for a document in state S then c1 moves the document from
	// S to S' and c2 from S' to S''. So c1 is computed on the state S and c2 is computed
	// on the state S'.
	// 
	// To mirror the content of a document using change events use the following approach:
	// - start with the same initial content
	// - apply the 'textDocument/didChange' notifications in the order you receive them.
	// - apply the `TextDocumentContentChangeEvent`s in a single notification in the order
	//   you receive them.
	content_changes: []TextDocumentContentChangeEvent `json:"contentChanges"`,
}

// Describe options to be used when registered for text document change events.
TextDocumentChangeRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// How documents are synced to the server.
	sync_kind: TextDocumentSyncKind `json:"syncKind"`,
}

// The parameters sent in a close text document notification
DidCloseTextDocumentParams :: struct {
	// The document that was closed.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
}

// The parameters sent in a save text document notification
DidSaveTextDocumentParams :: struct {
	// The document that was saved.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// Optional the content when saved. Depends on the includeText value
	// when the save notification was requested.
	text: Maybe(string) `json:"text,omitempty"`,
}

// Save registration options.
TextDocumentSaveRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// The client is supposed to include the content on save.
	include_text: Maybe(bool) `json:"includeText,omitempty"`,
}

// The parameters sent in a will save text document notification.
WillSaveTextDocumentParams :: struct {
	// The document that will be saved.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The 'TextDocumentSaveReason'.
	reason: TextDocumentSaveReason `json:"reason"`,
}

// A text edit applicable to a text document.
TextEdit :: struct {
	// The range of the text document to be manipulated. To insert
	// text into a document create a range where start === end.
	range: Range `json:"range"`,
	// The string to be inserted. For delete operations use an
	// empty string.
	new_text: string `json:"newText"`,
}

// The watched files change notification's parameters.
DidChangeWatchedFilesParams :: struct {
	// The actual file events.
	changes: []FileEvent `json:"changes"`,
}

// Describe options to be used when registered for text document change events.
DidChangeWatchedFilesRegistrationOptions :: struct {
	// The watchers to register.
	watchers: []FileSystemWatcher `json:"watchers"`,
}

// The publish diagnostic notification's parameters.
PublishDiagnosticsParams :: struct {
	// The URI for which diagnostic information is reported.
	uri: DocumentUri `json:"uri"`,
	// Optional the version number of the document the diagnostics are published for.
	// 
	// @since 3.15.0
	version: Maybe(i32) `json:"version,omitempty"`,
	// An array of diagnostic information items.
	diagnostics: []Diagnostic `json:"diagnostics"`,
}

// Completion parameters
CompletionParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The completion context. This is only available if the client specifies
	// to send this using the client capability `textDocument.completion.contextSupport === true`
	context_: Maybe(CompletionContext) `json:"context,omitempty"`,
}

// A completion item represents a text snippet that is
// proposed to complete text that is being typed.
CompletionItem :: struct {
	// The label of this completion item.
	// 
	// The label property is also by default the text that
	// is inserted when selecting this completion.
	// 
	// If label details are provided the label itself should
	// be an unqualified name of the completion item.
	label: string `json:"label"`,
	// Additional details for the label
	// 
	// @since 3.17.0
	label_details: Maybe(CompletionItemLabelDetails) `json:"labelDetails,omitempty"`,
	// The kind of this completion item. Based of the kind
	// an icon is chosen by the editor.
	kind: Maybe(CompletionItemKind) `json:"kind,omitempty"`,
	// Tags for this completion item.
	// 
	// @since 3.15.0
	tags: Maybe([]CompletionItemTag) `json:"tags,omitempty"`,
	// A human-readable string with additional information
	// about this item, like type or symbol information.
	detail: Maybe(string) `json:"detail,omitempty"`,
	// A human-readable string that represents a doc-comment.
	documentation: Maybe(union {string, MarkupContent}) `json:"documentation,omitempty"`,
	// Indicates if this item is deprecated.
	// @deprecated Use `tags` instead.
	deprecated: Maybe(bool) `json:"deprecated,omitempty"`,
	// Select this item when showing.
	// 
	// *Note* that only one completion item can be selected and that the
	// tool / client decides which item that is. The rule is that the *first*
	// item of those that match best is selected.
	preselect: Maybe(bool) `json:"preselect,omitempty"`,
	// A string that should be used when comparing this item
	// with other items. When `falsy` the {@link CompletionItem.label label}
	// is used.
	sort_text: Maybe(string) `json:"sortText,omitempty"`,
	// A string that should be used when filtering a set of
	// completion items. When `falsy` the {@link CompletionItem.label label}
	// is used.
	filter_text: Maybe(string) `json:"filterText,omitempty"`,
	// A string that should be inserted into a document when selecting
	// this completion. When `falsy` the {@link CompletionItem.label label}
	// is used.
	// 
	// The `insertText` is subject to interpretation by the client side.
	// Some tools might not take the string literally. For example
	// VS Code when code complete is requested in this example
	// `con<cursor position>` and a completion item with an `insertText` of
	// `console` is provided it will only insert `sole`. Therefore it is
	// recommended to use `textEdit` instead since it avoids additional client
	// side interpretation.
	insert_text: Maybe(string) `json:"insertText,omitempty"`,
	// The format of the insert text. The format applies to both the
	// `insertText` property and the `newText` property of a provided
	// `textEdit`. If omitted defaults to `InsertTextFormat.PlainText`.
	// 
	// Please note that the insertTextFormat doesn't apply to
	// `additionalTextEdits`.
	insert_text_format: Maybe(InsertTextFormat) `json:"insertTextFormat,omitempty"`,
	// How whitespace and indentation is handled during completion
	// item insertion. If not provided the clients default value depends on
	// the `textDocument.completion.insertTextMode` client capability.
	// 
	// @since 3.16.0
	insert_text_mode: Maybe(InsertTextMode) `json:"insertTextMode,omitempty"`,
	// An {@link TextEdit edit} which is applied to a document when selecting
	// this completion. When an edit is provided the value of
	// {@link CompletionItem.insertText insertText} is ignored.
	// 
	// Most editors support two different operations when accepting a completion
	// item. One is to insert a completion text and the other is to replace an
	// existing text with a completion text. Since this can usually not be
	// predetermined by a server it can report both ranges. Clients need to
	// signal support for `InsertReplaceEdits` via the
	// `textDocument.completion.insertReplaceSupport` client capability
	// property.
	// 
	// *Note 1:* The text edit's range as well as both ranges from an insert
	// replace edit must be a [single line] and they must contain the position
	// at which completion has been requested.
	// *Note 2:* If an `InsertReplaceEdit` is returned the edit's insert range
	// must be a prefix of the edit's replace range, that means it must be
	// contained and starting at the same position.
	// 
	// @since 3.16.0 additional type `InsertReplaceEdit`
	text_edit: Maybe(union {TextEdit, InsertReplaceEdit}) `json:"textEdit,omitempty"`,
	// The edit text used if the completion item is part of a CompletionList and
	// CompletionList defines an item default for the text edit range.
	// 
	// Clients will only honor this property if they opt into completion list
	// item defaults using the capability `completionList.itemDefaults`.
	// 
	// If not provided and a list's default range is provided the label
	// property is used as a text.
	// 
	// @since 3.17.0
	text_edit_text: Maybe(string) `json:"textEditText,omitempty"`,
	// An optional array of additional {@link TextEdit text edits} that are applied when
	// selecting this completion. Edits must not overlap (including the same insert position)
	// with the main {@link CompletionItem.textEdit edit} nor with themselves.
	// 
	// Additional text edits should be used to change text unrelated to the current cursor position
	// (for example adding an import statement at the top of the file if the completion item will
	// insert an unqualified type).
	additional_text_edits: Maybe([]TextEdit) `json:"additionalTextEdits,omitempty"`,
	// An optional set of characters that when pressed while this completion is active will accept it first and
	// then type that character. *Note* that all commit characters should have `length=1` and that superfluous
	// characters will be ignored.
	commit_characters: Maybe([]string) `json:"commitCharacters,omitempty"`,
	// An optional {@link Command command} that is executed *after* inserting this completion. *Note* that
	// additional modifications to the current document should be described with the
	// {@link CompletionItem.additionalTextEdits additionalTextEdits}-property.
	command: Maybe(Command) `json:"command,omitempty"`,
	// A data entry field that is preserved on a completion item between a
	// {@link CompletionRequest} and a {@link CompletionResolveRequest}.
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Represents a collection of {@link CompletionItem completion items} to be presented
// in the editor.
CompletionList :: struct {
	// This list it not complete. Further typing results in recomputing this list.
	// 
	// Recomputed lists have all their items replaced (not appended) in the
	// incomplete completion sessions.
	is_incomplete: bool `json:"isIncomplete"`,
	// In many cases the items of an actual completion result share the same
	// value for properties like `commitCharacters` or the range of a text
	// edit. A completion list can therefore define item defaults which will
	// be used if a completion item itself doesn't specify the value.
	// 
	// If a completion list specifies a default value and a completion item
	// also specifies a corresponding value the one from the item is used.
	// 
	// Servers are only allowed to return default values if the client
	// signals support for this via the `completionList.itemDefaults`
	// capability.
	// 
	// @since 3.17.0
	item_defaults: Maybe(CompletionListItemDefaults) `json:"itemDefaults,omitempty"`,
	// The completion items.
	items: []CompletionItem `json:"items"`,
}

// Registration options for a {@link CompletionRequest}.
CompletionRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Most tools trigger completion request automatically without explicitly requesting
	// it using a keyboard shortcut (e.g. Ctrl+Space). Typically they do so when the user
	// starts to type an identifier. For example if the user types `c` in a JavaScript file
	// code complete will automatically pop up present `console` besides others as a
	// completion item. Characters that make up identifiers don't need to be listed here.
	// 
	// If code complete should automatically be trigger on characters not being valid inside
	// an identifier (for example `.` in JavaScript) list them in `triggerCharacters`.
	trigger_characters: Maybe([]string) `json:"triggerCharacters,omitempty"`,
	// The list of all possible characters that commit a completion. This field can be used
	// if clients don't support individual commit characters per completion item. See
	// `ClientCapabilities.textDocument.completion.completionItem.commitCharactersSupport`
	// 
	// If a server provides both `allCommitCharacters` and commit characters on an individual
	// completion item the ones on the completion item win.
	// 
	// @since 3.2.0
	all_commit_characters: Maybe([]string) `json:"allCommitCharacters,omitempty"`,
	// The server provides support to resolve additional
	// information for a completion item.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
	// The server supports the following `CompletionItem` specific
	// capabilities.
	// 
	// @since 3.17.0
	completion_item: Maybe(CompletionRegistrationOptionsCompletionItem) `json:"completionItem,omitempty"`,
}

// Parameters for a {@link HoverRequest}.
HoverParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
}

// The result of a hover request.
Hover :: struct {
	// The hover's content
	contents: union {MarkupContent, MarkedString, []MarkedString} `json:"contents"`,
	// An optional range inside the text document that is used to
	// visualize the hover, e.g. by changing the background color.
	range: Maybe(Range) `json:"range,omitempty"`,
}

// Registration options for a {@link HoverRequest}.
HoverRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Parameters for a {@link SignatureHelpRequest}.
SignatureHelpParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The signature help context. This is only available if the client specifies
	// to send this using the client capability `textDocument.signatureHelp.contextSupport === true`
	// 
	// @since 3.15.0
	context_: Maybe(SignatureHelpContext) `json:"context,omitempty"`,
}

// Signature help represents the signature of something
// callable. There can be multiple signature but only one
// active and only one active parameter.
SignatureHelp :: struct {
	// One or more signatures.
	signatures: []SignatureInformation `json:"signatures"`,
	// The active signature. If omitted or the value lies outside the
	// range of `signatures` the value defaults to zero or is ignored if
	// the `SignatureHelp` has no signatures.
	// 
	// Whenever possible implementors should make an active decision about
	// the active signature and shouldn't rely on a default value.
	// 
	// In future version of the protocol this property might become
	// mandatory to better express this.
	active_signature: Maybe(u32) `json:"activeSignature,omitempty"`,
	// The active parameter of the active signature. If omitted or the value
	// lies outside the range of `signatures[activeSignature].parameters`
	// defaults to 0 if the active signature has parameters. If
	// the active signature has no parameters it is ignored.
	// In future version of the protocol this property might become
	// mandatory to better express the active parameter if the
	// active signature does have any.
	active_parameter: Maybe(u32) `json:"activeParameter,omitempty"`,
}

// Registration options for a {@link SignatureHelpRequest}.
SignatureHelpRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// List of characters that trigger signature help automatically.
	trigger_characters: Maybe([]string) `json:"triggerCharacters,omitempty"`,
	// List of characters that re-trigger signature help.
	// 
	// These trigger characters are only active when signature help is already showing. All trigger characters
	// are also counted as re-trigger characters.
	// 
	// @since 3.15.0
	retrigger_characters: Maybe([]string) `json:"retriggerCharacters,omitempty"`,
}

// Parameters for a {@link DefinitionRequest}.
DefinitionParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
}

// Registration options for a {@link DefinitionRequest}.
DefinitionRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Parameters for a {@link ReferencesRequest}.
ReferenceParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	context_: ReferenceContext `json:"context"`,
}

// Registration options for a {@link ReferencesRequest}.
ReferenceRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Parameters for a {@link DocumentHighlightRequest}.
DocumentHighlightParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
}

// A document highlight is a range inside a text document which deserves
// special attention. Usually a document highlight is visualized by changing
// the background color of its range.
DocumentHighlight :: struct {
	// The range this highlight applies to.
	range: Range `json:"range"`,
	// The highlight kind, default is {@link DocumentHighlightKind.Text text}.
	kind: Maybe(DocumentHighlightKind) `json:"kind,omitempty"`,
}

// Registration options for a {@link DocumentHighlightRequest}.
DocumentHighlightRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Parameters for a {@link DocumentSymbolRequest}.
DocumentSymbolParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
}

// Represents information about programming constructs like variables, classes,
// interfaces etc.
SymbolInformation :: struct {
	// The name of this symbol.
	name: string `json:"name"`,
	// The kind of this symbol.
	kind: SymbolKind `json:"kind"`,
	// Tags for this symbol.
	// 
	// @since 3.16.0
	tags: Maybe([]SymbolTag) `json:"tags,omitempty"`,
	// The name of the symbol containing this symbol. This information is for
	// user interface purposes (e.g. to render a qualifier in the user interface
	// if necessary). It can't be used to re-infer a hierarchy for the document
	// symbols.
	container_name: Maybe(string) `json:"containerName,omitempty"`,
	// Indicates if this symbol is deprecated.
	// 
	// @deprecated Use tags instead
	deprecated: Maybe(bool) `json:"deprecated,omitempty"`,
	// The location of this symbol. The location's range is used by a tool
	// to reveal the location in the editor. If the symbol is selected in the
	// tool the range's start information is used to position the cursor. So
	// the range usually spans more than the actual symbol's name and does
	// normally include things like visibility modifiers.
	// 
	// The range doesn't have to denote a node range in the sense of an abstract
	// syntax tree. It can therefore not be used to re-construct a hierarchy of
	// the symbols.
	location: Location `json:"location"`,
}

// Represents programming constructs like variables, classes, interfaces etc.
// that appear in a document. Document symbols can be hierarchical and they
// have two ranges: one that encloses its definition and one that points to
// its most interesting range, e.g. the range of an identifier.
DocumentSymbol :: struct {
	// The name of this symbol. Will be displayed in the user interface and therefore must not be
	// an empty string or a string only consisting of white spaces.
	name: string `json:"name"`,
	// More detail for this symbol, e.g the signature of a function.
	detail: Maybe(string) `json:"detail,omitempty"`,
	// The kind of this symbol.
	kind: SymbolKind `json:"kind"`,
	// Tags for this document symbol.
	// 
	// @since 3.16.0
	tags: Maybe([]SymbolTag) `json:"tags,omitempty"`,
	// Indicates if this symbol is deprecated.
	// 
	// @deprecated Use tags instead
	deprecated: Maybe(bool) `json:"deprecated,omitempty"`,
	// The range enclosing this symbol not including leading/trailing whitespace but everything else
	// like comments. This information is typically used to determine if the clients cursor is
	// inside the symbol to reveal in the symbol in the UI.
	range: Range `json:"range"`,
	// The range that should be selected and revealed when this symbol is being picked, e.g the name of a function.
	// Must be contained by the `range`.
	selection_range: Range `json:"selectionRange"`,
	// Children of this symbol, e.g. properties of a class.
	children: Maybe([]DocumentSymbol) `json:"children,omitempty"`,
}

// Registration options for a {@link DocumentSymbolRequest}.
DocumentSymbolRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// A human-readable string that is shown when multiple outlines trees
	// are shown for the same document.
	// 
	// @since 3.16.0
	label: Maybe(string) `json:"label,omitempty"`,
}

// The parameters of a {@link CodeActionRequest}.
CodeActionParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The document in which the command was invoked.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The range for which the command was invoked.
	range: Range `json:"range"`,
	// Context carrying additional information.
	context_: CodeActionContext `json:"context"`,
}

// Represents a reference to a command. Provides a title which
// will be used to represent a command in the UI and, optionally,
// an array of arguments which will be passed to the command handler
// function when invoked.
Command :: struct {
	// Title of the command, like `save`.
	title: string `json:"title"`,
	// The identifier of the actual command handler.
	command: string `json:"command"`,
	// Arguments that the command handler should be
	// invoked with.
	arguments: Maybe([]LSPAny) `json:"arguments,omitempty"`,
}

// A code action represents a change that can be performed in code, e.g. to fix a problem or
// to refactor code.
// 
// A CodeAction must set either `edit` and/or a `command`. If both are supplied, the `edit` is applied first, then the `command` is executed.
CodeAction :: struct {
	// A short, human-readable, title for this code action.
	title: string `json:"title"`,
	// The kind of the code action.
	// 
	// Used to filter code actions.
	kind: Maybe(CodeActionKind) `json:"kind,omitempty"`,
	// The diagnostics that this code action resolves.
	diagnostics: Maybe([]Diagnostic) `json:"diagnostics,omitempty"`,
	// Marks this as a preferred action. Preferred actions are used by the `auto fix` command and can be targeted
	// by keybindings.
	// 
	// A quick fix should be marked preferred if it properly addresses the underlying error.
	// A refactoring should be marked preferred if it is the most reasonable choice of actions to take.
	// 
	// @since 3.15.0
	is_preferred: Maybe(bool) `json:"isPreferred,omitempty"`,
	// Marks that the code action cannot currently be applied.
	// 
	// Clients should follow the following guidelines regarding disabled code actions:
	// 
	//   - Disabled code actions are not shown in automatic [lightbulbs](https://code.visualstudio.com/docs/editor/editingevolved#_code-action)
	//     code action menus.
	// 
	//   - Disabled actions are shown as faded out in the code action menu when the user requests a more specific type
	//     of code action, such as refactorings.
	// 
	//   - If the user has a [keybinding](https://code.visualstudio.com/docs/editor/refactoring#_keybindings-for-code-actions)
	//     that auto applies a code action and only disabled code actions are returned, the client should show the user an
	//     error message with `reason` in the editor.
	// 
	// @since 3.16.0
	disabled: Maybe(CodeActionDisabled) `json:"disabled,omitempty"`,
	// The workspace edit this code action performs.
	edit: Maybe(WorkspaceEdit) `json:"edit,omitempty"`,
	// A command this code action executes. If a code action
	// provides an edit and a command, first the edit is
	// executed and then the command.
	command: Maybe(Command) `json:"command,omitempty"`,
	// A data entry field that is preserved on a code action between
	// a `textDocument/codeAction` and a `codeAction/resolve` request.
	// 
	// @since 3.16.0
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Registration options for a {@link CodeActionRequest}.
CodeActionRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// CodeActionKinds that this server may return.
	// 
	// The list of kinds may be generic, such as `CodeActionKind.Refactor`, or the server
	// may list out every specific kind they provide.
	code_action_kinds: Maybe([]CodeActionKind) `json:"codeActionKinds,omitempty"`,
	// The server provides support to resolve additional
	// information for a code action.
	// 
	// @since 3.16.0
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// The parameters of a {@link WorkspaceSymbolRequest}.
WorkspaceSymbolParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// A query string to filter symbols by. Clients may send an empty
	// string here to request all symbols.
	query: string `json:"query"`,
}

// A special workspace symbol that supports locations without a range.
// 
// See also SymbolInformation.
// 
// @since 3.17.0
WorkspaceSymbol :: struct {
	// The name of this symbol.
	name: string `json:"name"`,
	// The kind of this symbol.
	kind: SymbolKind `json:"kind"`,
	// Tags for this symbol.
	// 
	// @since 3.16.0
	tags: Maybe([]SymbolTag) `json:"tags,omitempty"`,
	// The name of the symbol containing this symbol. This information is for
	// user interface purposes (e.g. to render a qualifier in the user interface
	// if necessary). It can't be used to re-infer a hierarchy for the document
	// symbols.
	container_name: Maybe(string) `json:"containerName,omitempty"`,
	// The location of the symbol. Whether a server is allowed to
	// return a location without a range depends on the client
	// capability `workspace.symbol.resolveSupport`.
	// 
	// See SymbolInformation#location for more details.
	location: union {Location, WorkspaceSymbolLocationVariant1} `json:"location"`,
	// A data entry field that is preserved on a workspace symbol between a
	// workspace symbol request and a workspace symbol resolve request.
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Registration options for a {@link WorkspaceSymbolRequest}.
WorkspaceSymbolRegistrationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The server provides support to resolve additional
	// information for a workspace symbol.
	// 
	// @since 3.17.0
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// The parameters of a {@link CodeLensRequest}.
CodeLensParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The document to request code lens for.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
}

// A code lens represents a {@link Command command} that should be shown along with
// source text, like the number of references, a way to run tests, etc.
// 
// A code lens is _unresolved_ when no command is associated to it. For performance
// reasons the creation of a code lens and resolving should be done in two stages.
CodeLens :: struct {
	// The range in which this code lens is valid. Should only span a single line.
	range: Range `json:"range"`,
	// The command this code lens represents.
	command: Maybe(Command) `json:"command,omitempty"`,
	// A data entry field that is preserved on a code lens item between
	// a {@link CodeLensRequest} and a {@link CodeLensResolveRequest}
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Registration options for a {@link CodeLensRequest}.
CodeLensRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Code lens has a resolve provider as well.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// The parameters of a {@link DocumentLinkRequest}.
DocumentLinkParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
	// The document to provide document links for.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
}

// A document link is a range in a text document that links to an internal or external resource, like another
// text document or a web site.
DocumentLink :: struct {
	// The range this link applies to.
	range: Range `json:"range"`,
	// The uri this link points to. If missing a resolve request is sent later.
	target: Maybe(URI) `json:"target,omitempty"`,
	// The tooltip text when you hover over this link.
	// 
	// If a tooltip is provided, is will be displayed in a string that includes instructions on how to
	// trigger the link, such as `{0} (ctrl + click)`. The specific instructions vary depending on OS,
	// user settings, and localization.
	// 
	// @since 3.15.0
	tooltip: Maybe(string) `json:"tooltip,omitempty"`,
	// A data entry field that is preserved on a document link between a
	// DocumentLinkRequest and a DocumentLinkResolveRequest.
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Registration options for a {@link DocumentLinkRequest}.
DocumentLinkRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Document links have a resolve provider as well.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// The parameters of a {@link DocumentFormattingRequest}.
DocumentFormattingParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The document to format.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The format options.
	options: FormattingOptions `json:"options"`,
}

// Registration options for a {@link DocumentFormattingRequest}.
DocumentFormattingRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// The parameters of a {@link DocumentRangeFormattingRequest}.
DocumentRangeFormattingParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The document to format.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The range to format
	range: Range `json:"range"`,
	// The format options
	options: FormattingOptions `json:"options"`,
}

// Registration options for a {@link DocumentRangeFormattingRequest}.
DocumentRangeFormattingRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Whether the server supports formatting multiple ranges at once.
	// 
	// @since 3.18.0
	// @proposed
	ranges_support: Maybe(bool) `json:"rangesSupport,omitempty"`,
}

// The parameters of a {@link DocumentRangesFormattingRequest}.
// 
// @since 3.18.0
// @proposed
DocumentRangesFormattingParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The document to format.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The ranges to format
	ranges: []Range `json:"ranges"`,
	// The format options
	options: FormattingOptions `json:"options"`,
}

// The parameters of a {@link DocumentOnTypeFormattingRequest}.
DocumentOnTypeFormattingParams :: struct {
	// The document to format.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position around which the on type formatting should happen.
	// This is not necessarily the exact position where the character denoted
	// by the property `ch` got typed.
	position: Position `json:"position"`,
	// The character that has been typed that triggered the formatting
	// on type request. That is not necessarily the last character that
	// got inserted into the document since the client could auto insert
	// characters as well (e.g. like automatic brace completion).
	ch: string `json:"ch"`,
	// The formatting options.
	options: FormattingOptions `json:"options"`,
}

// Registration options for a {@link DocumentOnTypeFormattingRequest}.
DocumentOnTypeFormattingRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	// A character on which formatting should be triggered, like `{`.
	first_trigger_character: string `json:"firstTriggerCharacter"`,
	// More trigger characters.
	more_trigger_character: Maybe([]string) `json:"moreTriggerCharacter,omitempty"`,
}

// The parameters of a {@link RenameRequest}.
RenameParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The document to rename.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position at which this request was sent.
	position: Position `json:"position"`,
	// The new name of the symbol. If the given name is not valid the
	// request must return a {@link ResponseError} with an
	// appropriate message set.
	new_name: string `json:"newName"`,
}

// Registration options for a {@link RenameRequest}.
RenameRegistrationOptions :: struct {
	// A document selector to identify the scope of the registration. If set to null
	// the document selector provided on the client side will be used.
	document_selector: Maybe(DocumentSelector) `json:"documentSelector,omitempty"`,
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Renames should be checked and tested before being executed.
	// 
	// @since version 3.12.0
	prepare_provider: Maybe(bool) `json:"prepareProvider,omitempty"`,
}

PrepareRenameParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
}

// The parameters of a {@link ExecuteCommandRequest}.
ExecuteCommandParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The identifier of the actual command handler.
	command: string `json:"command"`,
	// Arguments that the command should be invoked with.
	arguments: Maybe([]LSPAny) `json:"arguments,omitempty"`,
}

// Registration options for a {@link ExecuteCommandRequest}.
ExecuteCommandRegistrationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The commands to be executed on the server
	commands: []string `json:"commands"`,
}

// The parameters passed via an apply workspace edit request.
ApplyWorkspaceEditParams :: struct {
	// An optional label of the workspace edit. This label is
	// presented in the user interface for example on an undo
	// stack to undo the workspace edit.
	label: Maybe(string) `json:"label,omitempty"`,
	// The edits to apply.
	edit: WorkspaceEdit `json:"edit"`,
}

// The result returned from the apply workspace edit request.
// 
// @since 3.17 renamed from ApplyWorkspaceEditResponse
ApplyWorkspaceEditResult :: struct {
	// Indicates whether the edit was applied or not.
	applied: bool `json:"applied"`,
	// An optional textual description for why the edit was not applied.
	// This may be used by the server for diagnostic logging or to provide
	// a suitable error for a request that triggered the edit.
	failure_reason: Maybe(string) `json:"failureReason,omitempty"`,
	// Depending on the client's failure handling strategy `failedChange` might
	// contain the index of the change that failed. This property is only available
	// if the client signals a `failureHandlingStrategy` in its client capabilities.
	failed_change: Maybe(u32) `json:"failedChange,omitempty"`,
}

WorkDoneProgressBegin :: struct {
	kind: string `json:"kind"`,
	// Mandatory title of the progress operation. Used to briefly inform about
	// the kind of operation being performed.
	// 
	// Examples: "Indexing" or "Linking dependencies".
	title: string `json:"title"`,
	// Controls if a cancel button should show to allow the user to cancel the
	// long running operation. Clients that don't support cancellation are allowed
	// to ignore the setting.
	cancellable: Maybe(bool) `json:"cancellable,omitempty"`,
	// Optional, more detailed associated progress message. Contains
	// complementary information to the `title`.
	// 
	// Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
	// If unset, the previous progress message (if any) is still valid.
	message: Maybe(string) `json:"message,omitempty"`,
	// Optional progress percentage to display (value 100 is considered 100%).
	// If not provided infinite progress is assumed and clients are allowed
	// to ignore the `percentage` value in subsequent report notifications.
	// 
	// The value should be steadily rising. Clients are free to ignore values
	// that are not following this rule. The value range is [0, 100].
	percentage: Maybe(u32) `json:"percentage,omitempty"`,
}

WorkDoneProgressReport :: struct {
	kind: string `json:"kind"`,
	// Controls enablement state of a cancel button.
	// 
	// Clients that don't support cancellation or don't support controlling the button's
	// enablement state are allowed to ignore the property.
	cancellable: Maybe(bool) `json:"cancellable,omitempty"`,
	// Optional, more detailed associated progress message. Contains
	// complementary information to the `title`.
	// 
	// Examples: "3/25 files", "project/src/module2", "node_modules/some_dep".
	// If unset, the previous progress message (if any) is still valid.
	message: Maybe(string) `json:"message,omitempty"`,
	// Optional progress percentage to display (value 100 is considered 100%).
	// If not provided infinite progress is assumed and clients are allowed
	// to ignore the `percentage` value in subsequent report notifications.
	// 
	// The value should be steadily rising. Clients are free to ignore values
	// that are not following this rule. The value range is [0, 100].
	percentage: Maybe(u32) `json:"percentage,omitempty"`,
}

WorkDoneProgressEnd :: struct {
	kind: string `json:"kind"`,
	// Optional, a final message indicating to for example indicate the outcome
	// of the operation.
	message: Maybe(string) `json:"message,omitempty"`,
}

SetTraceParams :: struct {
	value: TraceValues `json:"value"`,
}

LogTraceParams :: struct {
	message: string `json:"message"`,
	verbose: Maybe(string) `json:"verbose,omitempty"`,
}

CancelParams :: struct {
	// The request id to cancel.
	id: union {i32, string} `json:"id"`,
}

ProgressParams :: struct {
	// The progress token provided by the client or server.
	token: ProgressToken `json:"token"`,
	// The progress data.
	value: LSPAny `json:"value"`,
}

// A parameter literal used in requests to pass a text document and a position inside that
// document.
TextDocumentPositionParams :: struct {
	// The text document.
	text_document: TextDocumentIdentifier `json:"textDocument"`,
	// The position inside the text document.
	position: Position `json:"position"`,
}

WorkDoneProgressParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
}

PartialResultParams :: struct {
	// An optional token that a server can use to report partial results (e.g. streaming) to
	// the client.
	partial_result_token: Maybe(ProgressToken) `json:"partialResultToken,omitempty"`,
}

// Represents the connection of two locations. Provides additional metadata over normal {@link Location locations},
// including an origin range.
LocationLink :: struct {
	// Span of the origin of this link.
	// 
	// Used as the underlined span for mouse interaction. Defaults to the word range at
	// the definition position.
	origin_selection_range: Maybe(Range) `json:"originSelectionRange,omitempty"`,
	// The target resource identifier of this link.
	target_uri: DocumentUri `json:"targetUri"`,
	// The full target range of this link. If the target for example is a symbol then target range is the
	// range enclosing this symbol not including leading/trailing whitespace but everything else
	// like comments. This information is typically used to highlight the range in the editor.
	target_range: Range `json:"targetRange"`,
	// The range that should be selected and revealed when this link is being followed, e.g the name of a function.
	// Must be contained by the `targetRange`. See also `DocumentSymbol#range`
	target_selection_range: Range `json:"targetSelectionRange"`,
}

// A range in a text document expressed as (zero-based) start and end positions.
// 
// If you want to specify a range that contains a line including the line ending
// character(s) then use an end position denoting the start of the next line.
// For example:
// ```ts
// {
//     start: { line: 5, character: 23 }
//     end : { line 6, character : 0 }
// }
// ```
Range :: struct {
	// The range's start position.
	start: Position `json:"start"`,
	// The range's end position.
	end: Position `json:"end"`,
}

ImplementationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Static registration options to be returned in the initialize
// request.
StaticRegistrationOptions :: struct {
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

TypeDefinitionOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// The workspace folder change event.
WorkspaceFoldersChangeEvent :: struct {
	// The array of added workspace folders
	added: []WorkspaceFolder `json:"added"`,
	// The array of the removed workspace folders
	removed: []WorkspaceFolder `json:"removed"`,
}

ConfigurationItem :: struct {
	// The scope to get the configuration section for.
	scope_uri: Maybe(URI) `json:"scopeUri,omitempty"`,
	// The configuration section asked for.
	section: Maybe(string) `json:"section,omitempty"`,
}

// A literal to identify a text document in the client.
TextDocumentIdentifier :: struct {
	// The text document's uri.
	uri: DocumentUri `json:"uri"`,
}

// Represents a color in RGBA space.
Color :: struct {
	// The red component of this color in the range [0-1].
	red: f64 `json:"red"`,
	// The green component of this color in the range [0-1].
	green: f64 `json:"green"`,
	// The blue component of this color in the range [0-1].
	blue: f64 `json:"blue"`,
	// The alpha component of this color in the range [0-1].
	alpha: f64 `json:"alpha"`,
}

DocumentColorOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

FoldingRangeOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

DeclarationOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Position in a text document expressed as zero-based line and character
// offset. Prior to 3.17 the offsets were always based on a UTF-16 string
// representation. So a string of the form `a𐐀b` the character offset of the
// character `a` is 0, the character offset of `𐐀` is 1 and the character
// offset of b is 3 since `𐐀` is represented using two code units in UTF-16.
// Since 3.17 clients and servers can agree on a different string encoding
// representation (e.g. UTF-8). The client announces it's supported encoding
// via the client capability [`general.positionEncodings`](https://microsoft.github.io/language-server-protocol/specifications/specification-current/#clientCapabilities).
// The value is an array of position encodings the client supports, with
// decreasing preference (e.g. the encoding at index `0` is the most preferred
// one). To stay backwards compatible the only mandatory encoding is UTF-16
// represented via the string `utf-16`. The server can pick one of the
// encodings offered by the client and signals that encoding back to the
// client via the initialize result's property
// [`capabilities.positionEncoding`](https://microsoft.github.io/language-server-protocol/specifications/specification-current/#serverCapabilities). If the string value
// `utf-16` is missing from the client's capability `general.positionEncodings`
// servers can safely assume that the client supports UTF-16. If the server
// omits the position encoding in its initialize result the encoding defaults
// to the string value `utf-16`. Implementation considerations: since the
// conversion from one encoding into another requires the content of the
// file / line the conversion is best done where the file is read which is
// usually on the server side.
// 
// Positions are line end character agnostic. So you can not specify a position
// that denotes `\r|\n` or `\n|` where `|` represents the character offset.
// 
// @since 3.17.0 - support for negotiated position encoding.
Position :: struct {
	// Line position in a document (zero-based).
	// 
	// If a line number is greater than the number of lines in a document, it defaults back to the number of lines in the document.
	// If a line number is negative, it defaults to 0.
	line: u32 `json:"line"`,
	// Character offset on a line in a document (zero-based).
	// 
	// The meaning of this offset is determined by the negotiated
	// `PositionEncodingKind`.
	// 
	// If the character value is greater than the line length it defaults back to the
	// line length.
	character: u32 `json:"character"`,
}

SelectionRangeOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Call hierarchy options used during static registration.
// 
// @since 3.16.0
CallHierarchyOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// @since 3.16.0
SemanticTokensOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The legend used by the server
	legend: SemanticTokensLegend `json:"legend"`,
	// Server supports providing semantic tokens for a specific range
	// of a document.
	range: Maybe(union {bool, SemanticTokensOptionsRangeVariant1}) `json:"range,omitempty"`,
	// Server supports providing semantic tokens for a full document.
	full: Maybe(union {bool, SemanticTokensOptionsFullVariant1}) `json:"full,omitempty"`,
}

// @since 3.16.0
SemanticTokensEdit :: struct {
	// The start offset of the edit.
	start: u32 `json:"start"`,
	// The count of elements to remove.
	delete_count: u32 `json:"deleteCount"`,
	// The elements to insert.
	data: Maybe([]u32) `json:"data,omitempty"`,
}

LinkedEditingRangeOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Represents information on a file/folder create.
// 
// @since 3.16.0
FileCreate :: struct {
	// A file:// URI for the location of the file/folder being created.
	uri: string `json:"uri"`,
}

// Describes textual changes on a text document. A TextDocumentEdit describes all changes
// on a document version Si and after they are applied move the document to version Si+1.
// So the creator of a TextDocumentEdit doesn't need to sort the array of edits or do any
// kind of ordering. However the edits must be non overlapping.
TextDocumentEdit :: struct {
	// The text document to change.
	text_document: OptionalVersionedTextDocumentIdentifier `json:"textDocument"`,
	// The edits to be applied.
	// 
	// @since 3.16.0 - support for AnnotatedTextEdit. This is guarded using a
	// client capability.
	edits: []union {TextEdit, AnnotatedTextEdit} `json:"edits"`,
}

// Create file operation.
CreateFile :: struct {
	// A create
	kind: string `json:"kind"`,
	// An optional annotation identifier describing the operation.
	// 
	// @since 3.16.0
	annotation_id: Maybe(ChangeAnnotationIdentifier) `json:"annotationId,omitempty"`,
	// The resource to create.
	uri: DocumentUri `json:"uri"`,
	// Additional options
	options: Maybe(CreateFileOptions) `json:"options,omitempty"`,
}

// Rename file operation
RenameFile :: struct {
	// A rename
	kind: string `json:"kind"`,
	// An optional annotation identifier describing the operation.
	// 
	// @since 3.16.0
	annotation_id: Maybe(ChangeAnnotationIdentifier) `json:"annotationId,omitempty"`,
	// The old (existing) location.
	old_uri: DocumentUri `json:"oldUri"`,
	// The new location.
	new_uri: DocumentUri `json:"newUri"`,
	// Rename options.
	options: Maybe(RenameFileOptions) `json:"options,omitempty"`,
}

// Delete file operation
DeleteFile :: struct {
	// A delete
	kind: string `json:"kind"`,
	// An optional annotation identifier describing the operation.
	// 
	// @since 3.16.0
	annotation_id: Maybe(ChangeAnnotationIdentifier) `json:"annotationId,omitempty"`,
	// The file to delete.
	uri: DocumentUri `json:"uri"`,
	// Delete options.
	options: Maybe(DeleteFileOptions) `json:"options,omitempty"`,
}

// Additional information that describes document changes.
// 
// @since 3.16.0
ChangeAnnotation :: struct {
	// A human-readable string describing the actual change. The string
	// is rendered prominent in the user interface.
	label: string `json:"label"`,
	// A flag which indicates that user confirmation is needed
	// before applying the change.
	needs_confirmation: Maybe(bool) `json:"needsConfirmation,omitempty"`,
	// A human-readable string which is rendered less prominent in
	// the user interface.
	description: Maybe(string) `json:"description,omitempty"`,
}

// A filter to describe in which file operation requests or notifications
// the server is interested in receiving.
// 
// @since 3.16.0
FileOperationFilter :: struct {
	// A Uri scheme like `file` or `untitled`.
	scheme: Maybe(string) `json:"scheme,omitempty"`,
	// The actual file operation pattern.
	pattern: FileOperationPattern `json:"pattern"`,
}

// Represents information on a file/folder rename.
// 
// @since 3.16.0
FileRename :: struct {
	// A file:// URI for the original location of the file/folder being renamed.
	old_uri: string `json:"oldUri"`,
	// A file:// URI for the new location of the file/folder being renamed.
	new_uri: string `json:"newUri"`,
}

// Represents information on a file/folder delete.
// 
// @since 3.16.0
FileDelete :: struct {
	// A file:// URI for the location of the file/folder being deleted.
	uri: string `json:"uri"`,
}

MonikerOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Type hierarchy options used during static registration.
// 
// @since 3.17.0
TypeHierarchyOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// @since 3.17.0
InlineValueContext :: struct {
	// The stack frame (as a DAP Id) where the execution has stopped.
	frame_id: i32 `json:"frameId"`,
	// The document range where execution has stopped.
	// Typically the end position of the range denotes the line where the inline values are shown.
	stopped_location: Range `json:"stoppedLocation"`,
}

// Provide inline value as text.
// 
// @since 3.17.0
InlineValueText :: struct {
	// The document range for which the inline value applies.
	range: Range `json:"range"`,
	// The text of the inline value.
	text: string `json:"text"`,
}

// Provide inline value through a variable lookup.
// If only a range is specified, the variable name will be extracted from the underlying document.
// An optional variable name can be used to override the extracted name.
// 
// @since 3.17.0
InlineValueVariableLookup :: struct {
	// The document range for which the inline value applies.
	// The range is used to extract the variable name from the underlying document.
	range: Range `json:"range"`,
	// If specified the name of the variable to look up.
	variable_name: Maybe(string) `json:"variableName,omitempty"`,
	// How to perform the lookup.
	case_sensitive_lookup: bool `json:"caseSensitiveLookup"`,
}

// Provide an inline value through an expression evaluation.
// If only a range is specified, the expression will be extracted from the underlying document.
// An optional expression can be used to override the extracted expression.
// 
// @since 3.17.0
InlineValueEvaluatableExpression :: struct {
	// The document range for which the inline value applies.
	// The range is used to extract the evaluatable expression from the underlying document.
	range: Range `json:"range"`,
	// If specified the expression overrides the extracted expression.
	expression: Maybe(string) `json:"expression,omitempty"`,
}

// Inline value options used during static registration.
// 
// @since 3.17.0
InlineValueOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// An inlay hint label part allows for interactive and composite labels
// of inlay hints.
// 
// @since 3.17.0
InlayHintLabelPart :: struct {
	// The value of this label part.
	value: string `json:"value"`,
	// The tooltip text when you hover over this label part. Depending on
	// the client capability `inlayHint.resolveSupport` clients might resolve
	// this property late using the resolve request.
	tooltip: Maybe(union {string, MarkupContent}) `json:"tooltip,omitempty"`,
	// An optional source code location that represents this
	// label part.
	// 
	// The editor will use this location for the hover and for code navigation
	// features: This part will become a clickable link that resolves to the
	// definition of the symbol at the given location (not necessarily the
	// location itself), it shows the hover that shows at the given location,
	// and it shows a context menu with further code navigation commands.
	// 
	// Depending on the client capability `inlayHint.resolveSupport` clients
	// might resolve this property late using the resolve request.
	location: Maybe(Location) `json:"location,omitempty"`,
	// An optional command for this label part.
	// 
	// Depending on the client capability `inlayHint.resolveSupport` clients
	// might resolve this property late using the resolve request.
	command: Maybe(Command) `json:"command,omitempty"`,
}

// A `MarkupContent` literal represents a string value which content is interpreted base on its
// kind flag. Currently the protocol supports `plaintext` and `markdown` as markup kinds.
// 
// If the kind is `markdown` then the value can contain fenced code blocks like in GitHub issues.
// See https://help.github.com/articles/creating-and-highlighting-code-blocks/#syntax-highlighting
// 
// Here is an example how such a string can be constructed using JavaScript / TypeScript:
// ```ts
// let markdown: MarkdownContent = {
//  kind: MarkupKind.Markdown,
//  value: [
//    '# Header',
//    'Some text',
//    '```typescript',
//    'someCode();',
//    '```'
//  ].join('\n')
// };
// ```
// 
// *Please Note* that clients might sanitize the return markdown. A client could decide to
// remove HTML from the markdown to avoid script execution.
MarkupContent :: struct {
	// The type of the Markup
	kind: MarkupKind `json:"kind"`,
	// The content itself
	value: string `json:"value"`,
}

// Inlay hint options used during static registration.
// 
// @since 3.17.0
InlayHintOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The server provides support to resolve additional
	// information for an inlay hint item.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// A full diagnostic report with a set of related documents.
// 
// @since 3.17.0
RelatedFullDocumentDiagnosticReport :: struct {
	// A full document diagnostic report.
	kind: string `json:"kind"`,
	// An optional result id. If provided it will
	// be sent on the next diagnostic request for the
	// same document.
	result_id: Maybe(string) `json:"resultId,omitempty"`,
	// The actual items.
	items: []Diagnostic `json:"items"`,
	// Diagnostics of related documents. This information is useful
	// in programming languages where code in a file A can generate
	// diagnostics in a file B which A depends on. An example of
	// such a language is C/C++ where marco definitions in a file
	// a.cpp and result in errors in a header file b.hpp.
	// 
	// @since 3.17.0
	related_documents: Maybe(map[DocumentUri]union {FullDocumentDiagnosticReport, UnchangedDocumentDiagnosticReport}) `json:"relatedDocuments,omitempty"`,
}

// An unchanged diagnostic report with a set of related documents.
// 
// @since 3.17.0
RelatedUnchangedDocumentDiagnosticReport :: struct {
	// A document diagnostic report indicating
	// no changes to the last result. A server can
	// only return `unchanged` if result ids are
	// provided.
	kind: string `json:"kind"`,
	// A result id which will be sent on the next
	// diagnostic request for the same document.
	result_id: string `json:"resultId"`,
	// Diagnostics of related documents. This information is useful
	// in programming languages where code in a file A can generate
	// diagnostics in a file B which A depends on. An example of
	// such a language is C/C++ where marco definitions in a file
	// a.cpp and result in errors in a header file b.hpp.
	// 
	// @since 3.17.0
	related_documents: Maybe(map[DocumentUri]union {FullDocumentDiagnosticReport, UnchangedDocumentDiagnosticReport}) `json:"relatedDocuments,omitempty"`,
}

// A diagnostic report with a full set of problems.
// 
// @since 3.17.0
FullDocumentDiagnosticReport :: struct {
	// A full document diagnostic report.
	kind: string `json:"kind"`,
	// An optional result id. If provided it will
	// be sent on the next diagnostic request for the
	// same document.
	result_id: Maybe(string) `json:"resultId,omitempty"`,
	// The actual items.
	items: []Diagnostic `json:"items"`,
}

// A diagnostic report indicating that the last returned
// report is still accurate.
// 
// @since 3.17.0
UnchangedDocumentDiagnosticReport :: struct {
	// A document diagnostic report indicating
	// no changes to the last result. A server can
	// only return `unchanged` if result ids are
	// provided.
	kind: string `json:"kind"`,
	// A result id which will be sent on the next
	// diagnostic request for the same document.
	result_id: string `json:"resultId"`,
}

// Diagnostic options.
// 
// @since 3.17.0
DiagnosticOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// An optional identifier under which the diagnostics are
	// managed by the client.
	identifier: Maybe(string) `json:"identifier,omitempty"`,
	// Whether the language has inter file dependencies meaning that
	// editing code in one file can result in a different diagnostic
	// set in another file. Inter file dependencies are common for
	// most programming languages and typically uncommon for linters.
	inter_file_dependencies: bool `json:"interFileDependencies"`,
	// The server provides support for workspace diagnostics as well.
	workspace_diagnostics: bool `json:"workspaceDiagnostics"`,
}

// A previous result id in a workspace pull request.
// 
// @since 3.17.0
PreviousResultId :: struct {
	// The URI for which the client knowns a
	// result id.
	uri: DocumentUri `json:"uri"`,
	// The value of the previous result id.
	value: string `json:"value"`,
}

// A notebook document.
// 
// @since 3.17.0
NotebookDocument :: struct {
	// The notebook document's uri.
	uri: URI `json:"uri"`,
	// The type of the notebook.
	notebook_type: string `json:"notebookType"`,
	// The version number of this document (it will increase after each
	// change, including undo/redo).
	version: i32 `json:"version"`,
	// Additional metadata stored with the notebook
	// document.
	// 
	// Note: should always be an object literal (e.g. LSPObject)
	metadata: Maybe(LSPObject) `json:"metadata,omitempty"`,
	// The cells of a notebook.
	cells: []NotebookCell `json:"cells"`,
}

// An item to transfer a text document from the client to the
// server.
TextDocumentItem :: struct {
	// The text document's uri.
	uri: DocumentUri `json:"uri"`,
	// The text document's language identifier.
	language_id: string `json:"languageId"`,
	// The version number of this document (it will increase after each
	// change, including undo/redo).
	version: i32 `json:"version"`,
	// The content of the opened text document.
	text: string `json:"text"`,
}

// A versioned notebook document identifier.
// 
// @since 3.17.0
VersionedNotebookDocumentIdentifier :: struct {
	// The version number of this notebook document.
	version: i32 `json:"version"`,
	// The notebook document's uri.
	uri: URI `json:"uri"`,
}

// A change event for a notebook document.
// 
// @since 3.17.0
NotebookDocumentChangeEvent :: struct {
	// The changed meta data if any.
	// 
	// Note: should always be an object literal (e.g. LSPObject)
	metadata: Maybe(LSPObject) `json:"metadata,omitempty"`,
	// Changes to cells
	cells: Maybe(NotebookDocumentChangeEventCells) `json:"cells,omitempty"`,
}

// A literal to identify a notebook document in the client.
// 
// @since 3.17.0
NotebookDocumentIdentifier :: struct {
	// The notebook document's uri.
	uri: URI `json:"uri"`,
}

// Provides information about the context in which an inline completion was requested.
// 
// @since 3.18.0
// @proposed
InlineCompletionContext :: struct {
	// Describes how the inline completion was triggered.
	trigger_kind: InlineCompletionTriggerKind `json:"triggerKind"`,
	// Provides information about the currently selected item in the autocomplete widget if it is visible.
	selected_completion_info: Maybe(SelectedCompletionInfo) `json:"selectedCompletionInfo,omitempty"`,
}

// A string value used as a snippet is a template which allows to insert text
// and to control the editor cursor when insertion happens.
// 
// A snippet can define tab stops and placeholders with `$1`, `$2`
// and `${3:foo}`. `$0` defines the final tab stop, it defaults to
// the end of the snippet. Variables are defined with `$name` and
// `${name:default value}`.
// 
// @since 3.18.0
// @proposed
StringValue :: struct {
	// The kind of string value.
	kind: string `json:"kind"`,
	// The snippet string.
	value: string `json:"value"`,
}

// Inline completion options used during static registration.
// 
// @since 3.18.0
// @proposed
InlineCompletionOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// General parameters to register for a notification or to register a provider.
Registration :: struct {
	// The id used to register the request. The id can be used to deregister
	// the request again.
	id: string `json:"id"`,
	// The method / capability to register for.
	method: string `json:"method"`,
	// Options necessary for the registration.
	register_options: Maybe(LSPAny) `json:"registerOptions,omitempty"`,
}

// General parameters to unregister a request or notification.
Unregistration :: struct {
	// The id used to unregister the request or notification. Usually an id
	// provided during the register request.
	id: string `json:"id"`,
	// The method to unregister for.
	method: string `json:"method"`,
}

// The initialize parameters
_InitializeParams :: struct {
	// An optional token that a server can use to report work done progress.
	work_done_token: Maybe(ProgressToken) `json:"workDoneToken,omitempty"`,
	// The process Id of the parent process that started
	// the server.
	// 
	// Is `null` if the process has not been started by another process.
	// If the parent process is not alive then the server should exit.
	process_id: Maybe(i32) `json:"processId,omitempty"`,
	// Information about the client
	// 
	// @since 3.15.0
	client_info: Maybe(_InitializeParamsClientInfo) `json:"clientInfo,omitempty"`,
	// The locale the client is currently showing the user interface
	// in. This must not necessarily be the locale of the operating
	// system.
	// 
	// Uses IETF language tags as the value's syntax
	// (See https://en.wikipedia.org/wiki/IETF_language_tag)
	// 
	// @since 3.16.0
	locale: Maybe(string) `json:"locale,omitempty"`,
	// The rootPath of the workspace. Is null
	// if no folder is open.
	// 
	// @deprecated in favour of rootUri.
	root_path: Maybe(string) `json:"rootPath,omitempty"`,
	// The rootUri of the workspace. Is null if no
	// folder is open. If both `rootPath` and `rootUri` are set
	// `rootUri` wins.
	// 
	// @deprecated in favour of workspaceFolders.
	root_uri: Maybe(DocumentUri) `json:"rootUri,omitempty"`,
	// The capabilities provided by the client (editor or tool)
	capabilities: ClientCapabilities `json:"capabilities"`,
	// User provided initialization options.
	initialization_options: Maybe(LSPAny) `json:"initializationOptions,omitempty"`,
	// The initial trace setting. If omitted trace is disabled ('off').
	trace: Maybe(TraceValues) `json:"trace,omitempty"`,
}

WorkspaceFoldersInitializeParams :: struct {
	// The workspace folders configured in the client when the server starts.
	// 
	// This property is only available if the client supports workspace folders.
	// It can be `null` if the client supports workspace folders but none are
	// configured.
	// 
	// @since 3.6.0
	workspace_folders: Maybe([]WorkspaceFolder) `json:"workspaceFolders,omitempty"`,
}

// Defines the capabilities provided by a language
// server.
ServerCapabilities :: struct {
	// The position encoding the server picked from the encodings offered
	// by the client via the client capability `general.positionEncodings`.
	// 
	// If the client didn't provide any position encodings the only valid
	// value that a server can return is 'utf-16'.
	// 
	// If omitted it defaults to 'utf-16'.
	// 
	// @since 3.17.0
	position_encoding: Maybe(PositionEncodingKind) `json:"positionEncoding,omitempty"`,
	// Defines how text documents are synced. Is either a detailed structure
	// defining each notification or for backwards compatibility the
	// TextDocumentSyncKind number.
	text_document_sync: Maybe(union {TextDocumentSyncOptions, TextDocumentSyncKind}) `json:"textDocumentSync,omitempty"`,
	// Defines how notebook documents are synced.
	// 
	// @since 3.17.0
	notebook_document_sync: Maybe(union {NotebookDocumentSyncOptions, NotebookDocumentSyncRegistrationOptions}) `json:"notebookDocumentSync,omitempty"`,
	// The server provides completion support.
	completion_provider: Maybe(CompletionOptions) `json:"completionProvider,omitempty"`,
	// The server provides hover support.
	hover_provider: Maybe(union {bool, HoverOptions}) `json:"hoverProvider,omitempty"`,
	// The server provides signature help support.
	signature_help_provider: Maybe(SignatureHelpOptions) `json:"signatureHelpProvider,omitempty"`,
	// The server provides Goto Declaration support.
	declaration_provider: Maybe(union {bool, DeclarationOptions, DeclarationRegistrationOptions}) `json:"declarationProvider,omitempty"`,
	// The server provides goto definition support.
	definition_provider: Maybe(union {bool, DefinitionOptions}) `json:"definitionProvider,omitempty"`,
	// The server provides Goto Type Definition support.
	type_definition_provider: Maybe(union {bool, TypeDefinitionOptions, TypeDefinitionRegistrationOptions}) `json:"typeDefinitionProvider,omitempty"`,
	// The server provides Goto Implementation support.
	implementation_provider: Maybe(union {bool, ImplementationOptions, ImplementationRegistrationOptions}) `json:"implementationProvider,omitempty"`,
	// The server provides find references support.
	references_provider: Maybe(union {bool, ReferenceOptions}) `json:"referencesProvider,omitempty"`,
	// The server provides document highlight support.
	document_highlight_provider: Maybe(union {bool, DocumentHighlightOptions}) `json:"documentHighlightProvider,omitempty"`,
	// The server provides document symbol support.
	document_symbol_provider: Maybe(union {bool, DocumentSymbolOptions}) `json:"documentSymbolProvider,omitempty"`,
	// The server provides code actions. CodeActionOptions may only be
	// specified if the client states that it supports
	// `codeActionLiteralSupport` in its initial `initialize` request.
	code_action_provider: Maybe(union {bool, CodeActionOptions}) `json:"codeActionProvider,omitempty"`,
	// The server provides code lens.
	code_lens_provider: Maybe(CodeLensOptions) `json:"codeLensProvider,omitempty"`,
	// The server provides document link support.
	document_link_provider: Maybe(DocumentLinkOptions) `json:"documentLinkProvider,omitempty"`,
	// The server provides color provider support.
	color_provider: Maybe(union {bool, DocumentColorOptions, DocumentColorRegistrationOptions}) `json:"colorProvider,omitempty"`,
	// The server provides workspace symbol support.
	workspace_symbol_provider: Maybe(union {bool, WorkspaceSymbolOptions}) `json:"workspaceSymbolProvider,omitempty"`,
	// The server provides document formatting.
	document_formatting_provider: Maybe(union {bool, DocumentFormattingOptions}) `json:"documentFormattingProvider,omitempty"`,
	// The server provides document range formatting.
	document_range_formatting_provider: Maybe(union {bool, DocumentRangeFormattingOptions}) `json:"documentRangeFormattingProvider,omitempty"`,
	// The server provides document formatting on typing.
	document_on_type_formatting_provider: Maybe(DocumentOnTypeFormattingOptions) `json:"documentOnTypeFormattingProvider,omitempty"`,
	// The server provides rename support. RenameOptions may only be
	// specified if the client states that it supports
	// `prepareSupport` in its initial `initialize` request.
	rename_provider: Maybe(union {bool, RenameOptions}) `json:"renameProvider,omitempty"`,
	// The server provides folding provider support.
	folding_range_provider: Maybe(union {bool, FoldingRangeOptions, FoldingRangeRegistrationOptions}) `json:"foldingRangeProvider,omitempty"`,
	// The server provides selection range support.
	selection_range_provider: Maybe(union {bool, SelectionRangeOptions, SelectionRangeRegistrationOptions}) `json:"selectionRangeProvider,omitempty"`,
	// The server provides execute command support.
	execute_command_provider: Maybe(ExecuteCommandOptions) `json:"executeCommandProvider,omitempty"`,
	// The server provides call hierarchy support.
	// 
	// @since 3.16.0
	call_hierarchy_provider: Maybe(union {bool, CallHierarchyOptions, CallHierarchyRegistrationOptions}) `json:"callHierarchyProvider,omitempty"`,
	// The server provides linked editing range support.
	// 
	// @since 3.16.0
	linked_editing_range_provider: Maybe(union {bool, LinkedEditingRangeOptions, LinkedEditingRangeRegistrationOptions}) `json:"linkedEditingRangeProvider,omitempty"`,
	// The server provides semantic tokens support.
	// 
	// @since 3.16.0
	semantic_tokens_provider: Maybe(union {SemanticTokensOptions, SemanticTokensRegistrationOptions}) `json:"semanticTokensProvider,omitempty"`,
	// The server provides moniker support.
	// 
	// @since 3.16.0
	moniker_provider: Maybe(union {bool, MonikerOptions, MonikerRegistrationOptions}) `json:"monikerProvider,omitempty"`,
	// The server provides type hierarchy support.
	// 
	// @since 3.17.0
	type_hierarchy_provider: Maybe(union {bool, TypeHierarchyOptions, TypeHierarchyRegistrationOptions}) `json:"typeHierarchyProvider,omitempty"`,
	// The server provides inline values.
	// 
	// @since 3.17.0
	inline_value_provider: Maybe(union {bool, InlineValueOptions, InlineValueRegistrationOptions}) `json:"inlineValueProvider,omitempty"`,
	// The server provides inlay hints.
	// 
	// @since 3.17.0
	inlay_hint_provider: Maybe(union {bool, InlayHintOptions, InlayHintRegistrationOptions}) `json:"inlayHintProvider,omitempty"`,
	// The server has support for pull model diagnostics.
	// 
	// @since 3.17.0
	diagnostic_provider: Maybe(union {DiagnosticOptions, DiagnosticRegistrationOptions}) `json:"diagnosticProvider,omitempty"`,
	// Inline completion options used during static registration.
	// 
	// @since 3.18.0
	// @proposed
	inline_completion_provider: Maybe(union {bool, InlineCompletionOptions}) `json:"inlineCompletionProvider,omitempty"`,
	// Workspace specific server capabilities.
	workspace: Maybe(ServerCapabilitiesWorkspace) `json:"workspace,omitempty"`,
	// Experimental server capabilities.
	experimental: Maybe(LSPAny) `json:"experimental,omitempty"`,
}

// A text document identifier to denote a specific version of a text document.
VersionedTextDocumentIdentifier :: struct {
	// The text document's uri.
	uri: DocumentUri `json:"uri"`,
	// The version number of this document.
	version: i32 `json:"version"`,
}

// Save options.
SaveOptions :: struct {
	// The client is supposed to include the content on save.
	include_text: Maybe(bool) `json:"includeText,omitempty"`,
}

// An event describing a file change.
FileEvent :: struct {
	// The file's uri.
	uri: DocumentUri `json:"uri"`,
	// The change type.
	type: FileChangeType `json:"type"`,
}

FileSystemWatcher :: struct {
	// The glob pattern to watch. See {@link GlobPattern glob pattern} for more detail.
	// 
	// @since 3.17.0 support for relative patterns.
	glob_pattern: GlobPattern `json:"globPattern"`,
	// The kind of events of interest. If omitted it defaults
	// to WatchKind.Create | WatchKind.Change | WatchKind.Delete
	// which is 7.
	kind: Maybe(WatchKind) `json:"kind,omitempty"`,
}

// Represents a diagnostic, such as a compiler error or warning. Diagnostic objects
// are only valid in the scope of a resource.
Diagnostic :: struct {
	// The range at which the message applies
	range: Range `json:"range"`,
	// The diagnostic's severity. Can be omitted. If omitted it is up to the
	// client to interpret diagnostics as error, warning, info or hint.
	severity: Maybe(DiagnosticSeverity) `json:"severity,omitempty"`,
	// The diagnostic's code, which usually appear in the user interface.
	code: Maybe(union {i32, string}) `json:"code,omitempty"`,
	// An optional property to describe the error code.
	// Requires the code field (above) to be present/not null.
	// 
	// @since 3.16.0
	code_description: Maybe(CodeDescription) `json:"codeDescription,omitempty"`,
	// A human-readable string describing the source of this
	// diagnostic, e.g. 'typescript' or 'super lint'. It usually
	// appears in the user interface.
	source: Maybe(string) `json:"source,omitempty"`,
	// The diagnostic's message. It usually appears in the user interface
	message: string `json:"message"`,
	// Additional metadata about the diagnostic.
	// 
	// @since 3.15.0
	tags: Maybe([]DiagnosticTag) `json:"tags,omitempty"`,
	// An array of related diagnostic information, e.g. when symbol-names within
	// a scope collide all definitions can be marked via this property.
	related_information: Maybe([]DiagnosticRelatedInformation) `json:"relatedInformation,omitempty"`,
	// A data entry field that is preserved between a `textDocument/publishDiagnostics`
	// notification and `textDocument/codeAction` request.
	// 
	// @since 3.16.0
	data: Maybe(LSPAny) `json:"data,omitempty"`,
}

// Contains additional information about the context in which a completion request is triggered.
CompletionContext :: struct {
	// How the completion was triggered.
	trigger_kind: CompletionTriggerKind `json:"triggerKind"`,
	// The trigger character (a single character) that has trigger code complete.
	// Is undefined if `triggerKind !== CompletionTriggerKind.TriggerCharacter`
	trigger_character: Maybe(string) `json:"triggerCharacter,omitempty"`,
}

// Additional details for a completion item label.
// 
// @since 3.17.0
CompletionItemLabelDetails :: struct {
	// An optional string which is rendered less prominently directly after {@link CompletionItem.label label},
	// without any spacing. Should be used for function signatures and type annotations.
	detail: Maybe(string) `json:"detail,omitempty"`,
	// An optional string which is rendered less prominently after {@link CompletionItem.detail}. Should be used
	// for fully qualified names and file paths.
	description: Maybe(string) `json:"description,omitempty"`,
}

// A special text edit to provide an insert and a replace operation.
// 
// @since 3.16.0
InsertReplaceEdit :: struct {
	// The string to be inserted.
	new_text: string `json:"newText"`,
	// The range if the insert is requested
	insert: Range `json:"insert"`,
	// The range if the replace is requested.
	replace: Range `json:"replace"`,
}

// Completion options.
CompletionOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Most tools trigger completion request automatically without explicitly requesting
	// it using a keyboard shortcut (e.g. Ctrl+Space). Typically they do so when the user
	// starts to type an identifier. For example if the user types `c` in a JavaScript file
	// code complete will automatically pop up present `console` besides others as a
	// completion item. Characters that make up identifiers don't need to be listed here.
	// 
	// If code complete should automatically be trigger on characters not being valid inside
	// an identifier (for example `.` in JavaScript) list them in `triggerCharacters`.
	trigger_characters: Maybe([]string) `json:"triggerCharacters,omitempty"`,
	// The list of all possible characters that commit a completion. This field can be used
	// if clients don't support individual commit characters per completion item. See
	// `ClientCapabilities.textDocument.completion.completionItem.commitCharactersSupport`
	// 
	// If a server provides both `allCommitCharacters` and commit characters on an individual
	// completion item the ones on the completion item win.
	// 
	// @since 3.2.0
	all_commit_characters: Maybe([]string) `json:"allCommitCharacters,omitempty"`,
	// The server provides support to resolve additional
	// information for a completion item.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
	// The server supports the following `CompletionItem` specific
	// capabilities.
	// 
	// @since 3.17.0
	completion_item: Maybe(CompletionOptionsCompletionItem) `json:"completionItem,omitempty"`,
}

// Hover options.
HoverOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Additional information about the context in which a signature help request was triggered.
// 
// @since 3.15.0
SignatureHelpContext :: struct {
	// Action that caused signature help to be triggered.
	trigger_kind: SignatureHelpTriggerKind `json:"triggerKind"`,
	// Character that caused signature help to be triggered.
	// 
	// This is undefined when `triggerKind !== SignatureHelpTriggerKind.TriggerCharacter`
	trigger_character: Maybe(string) `json:"triggerCharacter,omitempty"`,
	// `true` if signature help was already showing when it was triggered.
	// 
	// Retriggers occurs when the signature help is already active and can be caused by actions such as
	// typing a trigger character, a cursor move, or document content changes.
	is_retrigger: bool `json:"isRetrigger"`,
	// The currently active `SignatureHelp`.
	// 
	// The `activeSignatureHelp` has its `SignatureHelp.activeSignature` field updated based on
	// the user navigating through available signatures.
	active_signature_help: Maybe(SignatureHelp) `json:"activeSignatureHelp,omitempty"`,
}

// Represents the signature of something callable. A signature
// can have a label, like a function-name, a doc-comment, and
// a set of parameters.
SignatureInformation :: struct {
	// The label of this signature. Will be shown in
	// the UI.
	label: string `json:"label"`,
	// The human-readable doc-comment of this signature. Will be shown
	// in the UI but can be omitted.
	documentation: Maybe(union {string, MarkupContent}) `json:"documentation,omitempty"`,
	// The parameters of this signature.
	parameters: Maybe([]ParameterInformation) `json:"parameters,omitempty"`,
	// The index of the active parameter.
	// 
	// If provided, this is used in place of `SignatureHelp.activeParameter`.
	// 
	// @since 3.16.0
	active_parameter: Maybe(u32) `json:"activeParameter,omitempty"`,
}

// Server Capabilities for a {@link SignatureHelpRequest}.
SignatureHelpOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// List of characters that trigger signature help automatically.
	trigger_characters: Maybe([]string) `json:"triggerCharacters,omitempty"`,
	// List of characters that re-trigger signature help.
	// 
	// These trigger characters are only active when signature help is already showing. All trigger characters
	// are also counted as re-trigger characters.
	// 
	// @since 3.15.0
	retrigger_characters: Maybe([]string) `json:"retriggerCharacters,omitempty"`,
}

// Server Capabilities for a {@link DefinitionRequest}.
DefinitionOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Value-object that contains additional information when
// requesting references.
ReferenceContext :: struct {
	// Include the declaration of the current symbol.
	include_declaration: bool `json:"includeDeclaration"`,
}

// Reference options.
ReferenceOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Provider options for a {@link DocumentHighlightRequest}.
DocumentHighlightOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// A base for all symbol information.
BaseSymbolInformation :: struct {
	// The name of this symbol.
	name: string `json:"name"`,
	// The kind of this symbol.
	kind: SymbolKind `json:"kind"`,
	// Tags for this symbol.
	// 
	// @since 3.16.0
	tags: Maybe([]SymbolTag) `json:"tags,omitempty"`,
	// The name of the symbol containing this symbol. This information is for
	// user interface purposes (e.g. to render a qualifier in the user interface
	// if necessary). It can't be used to re-infer a hierarchy for the document
	// symbols.
	container_name: Maybe(string) `json:"containerName,omitempty"`,
}

// Provider options for a {@link DocumentSymbolRequest}.
DocumentSymbolOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// A human-readable string that is shown when multiple outlines trees
	// are shown for the same document.
	// 
	// @since 3.16.0
	label: Maybe(string) `json:"label,omitempty"`,
}

// Contains additional diagnostic information about the context in which
// a {@link CodeActionProvider.provideCodeActions code action} is run.
CodeActionContext :: struct {
	// An array of diagnostics known on the client side overlapping the range provided to the
	// `textDocument/codeAction` request. They are provided so that the server knows which
	// errors are currently presented to the user for the given range. There is no guarantee
	// that these accurately reflect the error state of the resource. The primary parameter
	// to compute code actions is the provided range.
	diagnostics: []Diagnostic `json:"diagnostics"`,
	// Requested kind of actions to return.
	// 
	// Actions not of this kind are filtered out by the client before being shown. So servers
	// can omit computing them.
	only: Maybe([]CodeActionKind) `json:"only,omitempty"`,
	// The reason why code actions were requested.
	// 
	// @since 3.17.0
	trigger_kind: Maybe(CodeActionTriggerKind) `json:"triggerKind,omitempty"`,
}

// Provider options for a {@link CodeActionRequest}.
CodeActionOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// CodeActionKinds that this server may return.
	// 
	// The list of kinds may be generic, such as `CodeActionKind.Refactor`, or the server
	// may list out every specific kind they provide.
	code_action_kinds: Maybe([]CodeActionKind) `json:"codeActionKinds,omitempty"`,
	// The server provides support to resolve additional
	// information for a code action.
	// 
	// @since 3.16.0
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// Server capabilities for a {@link WorkspaceSymbolRequest}.
WorkspaceSymbolOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The server provides support to resolve additional
	// information for a workspace symbol.
	// 
	// @since 3.17.0
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// Code Lens provider options of a {@link CodeLensRequest}.
CodeLensOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Code lens has a resolve provider as well.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// Provider options for a {@link DocumentLinkRequest}.
DocumentLinkOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Document links have a resolve provider as well.
	resolve_provider: Maybe(bool) `json:"resolveProvider,omitempty"`,
}

// Value-object describing what options formatting should use.
FormattingOptions :: struct {
	// Size of a tab in spaces.
	tab_size: u32 `json:"tabSize"`,
	// Prefer spaces over tabs.
	insert_spaces: bool `json:"insertSpaces"`,
	// Trim trailing whitespace on a line.
	// 
	// @since 3.15.0
	trim_trailing_whitespace: Maybe(bool) `json:"trimTrailingWhitespace,omitempty"`,
	// Insert a newline character at the end of the file if one does not exist.
	// 
	// @since 3.15.0
	insert_final_newline: Maybe(bool) `json:"insertFinalNewline,omitempty"`,
	// Trim all newlines after the final newline at the end of the file.
	// 
	// @since 3.15.0
	trim_final_newlines: Maybe(bool) `json:"trimFinalNewlines,omitempty"`,
}

// Provider options for a {@link DocumentFormattingRequest}.
DocumentFormattingOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
}

// Provider options for a {@link DocumentRangeFormattingRequest}.
DocumentRangeFormattingOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Whether the server supports formatting multiple ranges at once.
	// 
	// @since 3.18.0
	// @proposed
	ranges_support: Maybe(bool) `json:"rangesSupport,omitempty"`,
}

// Provider options for a {@link DocumentOnTypeFormattingRequest}.
DocumentOnTypeFormattingOptions :: struct {
	// A character on which formatting should be triggered, like `{`.
	first_trigger_character: string `json:"firstTriggerCharacter"`,
	// More trigger characters.
	more_trigger_character: Maybe([]string) `json:"moreTriggerCharacter,omitempty"`,
}

// Provider options for a {@link RenameRequest}.
RenameOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Renames should be checked and tested before being executed.
	// 
	// @since version 3.12.0
	prepare_provider: Maybe(bool) `json:"prepareProvider,omitempty"`,
}

// The server capabilities of a {@link ExecuteCommandRequest}.
ExecuteCommandOptions :: struct {
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// The commands to be executed on the server
	commands: []string `json:"commands"`,
}

// @since 3.16.0
SemanticTokensLegend :: struct {
	// The token types a server uses.
	token_types: []string `json:"tokenTypes"`,
	// The token modifiers a server uses.
	token_modifiers: []string `json:"tokenModifiers"`,
}

// A text document identifier to optionally denote a specific version of a text document.
OptionalVersionedTextDocumentIdentifier :: struct {
	// The text document's uri.
	uri: DocumentUri `json:"uri"`,
	// The version number of this document. If a versioned text document identifier
	// is sent from the server to the client and the file is not open in the editor
	// (the server has not received an open notification before) the server can send
	// `null` to indicate that the version is unknown and the content on disk is the
	// truth (as specified with document content ownership).
	version: Maybe(i32) `json:"version,omitempty"`,
}

// A special text edit with an additional change annotation.
// 
// @since 3.16.0.
AnnotatedTextEdit :: struct {
	// The range of the text document to be manipulated. To insert
	// text into a document create a range where start === end.
	range: Range `json:"range"`,
	// The string to be inserted. For delete operations use an
	// empty string.
	new_text: string `json:"newText"`,
	// The actual identifier of the change annotation
	annotation_id: ChangeAnnotationIdentifier `json:"annotationId"`,
}

// A generic resource operation.
ResourceOperation :: struct {
	// The resource operation kind.
	kind: string `json:"kind"`,
	// An optional annotation identifier describing the operation.
	// 
	// @since 3.16.0
	annotation_id: Maybe(ChangeAnnotationIdentifier) `json:"annotationId,omitempty"`,
}

// Options to create a file.
CreateFileOptions :: struct {
	// Overwrite existing file. Overwrite wins over `ignoreIfExists`
	overwrite: Maybe(bool) `json:"overwrite,omitempty"`,
	// Ignore if exists.
	ignore_if_exists: Maybe(bool) `json:"ignoreIfExists,omitempty"`,
}

// Rename file options
RenameFileOptions :: struct {
	// Overwrite target if existing. Overwrite wins over `ignoreIfExists`
	overwrite: Maybe(bool) `json:"overwrite,omitempty"`,
	// Ignores if target exists.
	ignore_if_exists: Maybe(bool) `json:"ignoreIfExists,omitempty"`,
}

// Delete file options
DeleteFileOptions :: struct {
	// Delete the content recursively if a folder is denoted.
	recursive: Maybe(bool) `json:"recursive,omitempty"`,
	// Ignore the operation if the file doesn't exist.
	ignore_if_not_exists: Maybe(bool) `json:"ignoreIfNotExists,omitempty"`,
}

// A pattern to describe in which file operation requests or notifications
// the server is interested in receiving.
// 
// @since 3.16.0
FileOperationPattern :: struct {
	// The glob pattern to match. Glob patterns can have the following syntax:
	// - `*` to match zero or more characters in a path segment
	// - `?` to match on one character in a path segment
	// - `**` to match any number of path segments, including none
	// - `{}` to group sub patterns into an OR expression. (e.g. `**​/*.{ts,js}` matches all TypeScript and JavaScript files)
	// - `[]` to declare a range of characters to match in a path segment (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
	// - `[!...]` to negate a range of characters to match in a path segment (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but not `example.0`)
	glob: string `json:"glob"`,
	// Whether to match files or folders with this pattern.
	// 
	// Matches both if undefined.
	matches: Maybe(FileOperationPatternKind) `json:"matches,omitempty"`,
	// Additional options used during matching.
	options: Maybe(FileOperationPatternOptions) `json:"options,omitempty"`,
}

// A full document diagnostic report for a workspace diagnostic result.
// 
// @since 3.17.0
WorkspaceFullDocumentDiagnosticReport :: struct {
	// A full document diagnostic report.
	kind: string `json:"kind"`,
	// An optional result id. If provided it will
	// be sent on the next diagnostic request for the
	// same document.
	result_id: Maybe(string) `json:"resultId,omitempty"`,
	// The actual items.
	items: []Diagnostic `json:"items"`,
	// The URI for which diagnostic information is reported.
	uri: DocumentUri `json:"uri"`,
	// The version number for which the diagnostics are reported.
	// If the document is not marked as open `null` can be provided.
	version: Maybe(i32) `json:"version,omitempty"`,
}

// An unchanged document diagnostic report for a workspace diagnostic result.
// 
// @since 3.17.0
WorkspaceUnchangedDocumentDiagnosticReport :: struct {
	// A document diagnostic report indicating
	// no changes to the last result. A server can
	// only return `unchanged` if result ids are
	// provided.
	kind: string `json:"kind"`,
	// A result id which will be sent on the next
	// diagnostic request for the same document.
	result_id: string `json:"resultId"`,
	// The URI for which diagnostic information is reported.
	uri: DocumentUri `json:"uri"`,
	// The version number for which the diagnostics are reported.
	// If the document is not marked as open `null` can be provided.
	version: Maybe(i32) `json:"version,omitempty"`,
}

// A notebook cell.
// 
// A cell's document URI must be unique across ALL notebook
// cells and can therefore be used to uniquely identify a
// notebook cell or the cell's text document.
// 
// @since 3.17.0
NotebookCell :: struct {
	// The cell's kind
	kind: NotebookCellKind `json:"kind"`,
	// The URI of the cell's text document
	// content.
	document: DocumentUri `json:"document"`,
	// Additional metadata stored with the cell.
	// 
	// Note: should always be an object literal (e.g. LSPObject)
	metadata: Maybe(LSPObject) `json:"metadata,omitempty"`,
	// Additional execution summary information
	// if supported by the client.
	execution_summary: Maybe(ExecutionSummary) `json:"executionSummary,omitempty"`,
}

// A change describing how to move a `NotebookCell`
// array from state S to S'.
// 
// @since 3.17.0
NotebookCellArrayChange :: struct {
	// The start oftest of the cell that changed.
	start: u32 `json:"start"`,
	// The deleted cells
	delete_count: u32 `json:"deleteCount"`,
	// The new cells, if any
	cells: Maybe([]NotebookCell) `json:"cells,omitempty"`,
}

// Describes the currently selected completion item.
// 
// @since 3.18.0
// @proposed
SelectedCompletionInfo :: struct {
	// The range that will be replaced if this completion item is accepted.
	range: Range `json:"range"`,
	// The text the range will be replaced with if this completion is accepted.
	text: string `json:"text"`,
}

// Defines the capabilities provided by the client.
ClientCapabilities :: struct {
	// Workspace specific client capabilities.
	workspace: Maybe(WorkspaceClientCapabilities) `json:"workspace,omitempty"`,
	// Text document specific client capabilities.
	text_document: Maybe(TextDocumentClientCapabilities) `json:"textDocument,omitempty"`,
	// Capabilities specific to the notebook document support.
	// 
	// @since 3.17.0
	notebook_document: Maybe(NotebookDocumentClientCapabilities) `json:"notebookDocument,omitempty"`,
	// Window specific client capabilities.
	window: Maybe(WindowClientCapabilities) `json:"window,omitempty"`,
	// General client capabilities.
	// 
	// @since 3.16.0
	general: Maybe(GeneralClientCapabilities) `json:"general,omitempty"`,
	// Experimental client capabilities.
	experimental: Maybe(LSPAny) `json:"experimental,omitempty"`,
}

TextDocumentSyncOptions :: struct {
	// Open and close notifications are sent to the server. If omitted open close notification should not
	// be sent.
	open_close: Maybe(bool) `json:"openClose,omitempty"`,
	// Change notifications are sent to the server. See TextDocumentSyncKind.None, TextDocumentSyncKind.Full
	// and TextDocumentSyncKind.Incremental. If omitted it defaults to TextDocumentSyncKind.None.
	change: Maybe(TextDocumentSyncKind) `json:"change,omitempty"`,
	// If present will save notifications are sent to the server. If omitted the notification should not be
	// sent.
	will_save: Maybe(bool) `json:"willSave,omitempty"`,
	// If present will save wait until requests are sent to the server. If omitted the request should not be
	// sent.
	will_save_wait_until: Maybe(bool) `json:"willSaveWaitUntil,omitempty"`,
	// If present save notifications are sent to the server. If omitted the notification should not be
	// sent.
	save: Maybe(union {bool, SaveOptions}) `json:"save,omitempty"`,
}

// Options specific to a notebook plus its cells
// to be synced to the server.
// 
// If a selector provides a notebook document
// filter but no cell selector all cells of a
// matching notebook document will be synced.
// 
// If a selector provides no notebook document
// filter but only a cell selector all notebook
// document that contain at least one matching
// cell will be synced.
// 
// @since 3.17.0
NotebookDocumentSyncOptions :: struct {
	// The notebooks to be synced
	notebook_selector: []union {NotebookDocumentSyncOptionsNotebookSelectorItemVariant0, NotebookDocumentSyncOptionsNotebookSelectorItemVariant1} `json:"notebookSelector"`,
	// Whether save notification should be forwarded to
	// the server. Will only be honored if mode === `notebook`.
	save: Maybe(bool) `json:"save,omitempty"`,
}

// Registration options specific to a notebook.
// 
// @since 3.17.0
NotebookDocumentSyncRegistrationOptions :: struct {
	// The notebooks to be synced
	notebook_selector: []union {NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant0, NotebookDocumentSyncRegistrationOptionsNotebookSelectorItemVariant1} `json:"notebookSelector"`,
	// Whether save notification should be forwarded to
	// the server. Will only be honored if mode === `notebook`.
	save: Maybe(bool) `json:"save,omitempty"`,
	// The id used to register the request. The id can be used to deregister
	// the request again. See also Registration#id.
	id: Maybe(string) `json:"id,omitempty"`,
}

WorkspaceFoldersServerCapabilities :: struct {
	// The server has support for workspace folders
	supported: Maybe(bool) `json:"supported,omitempty"`,
	// Whether the server wants to receive workspace folder
	// change notifications.
	// 
	// If a string is provided the string is treated as an ID
	// under which the notification is registered on the client
	// side. The ID can be used to unregister for these events
	// using the `client/unregisterCapability` request.
	change_notifications: Maybe(union {string, bool}) `json:"changeNotifications,omitempty"`,
}

// Options for notifications/requests for user operations on files.
// 
// @since 3.16.0
FileOperationOptions :: struct {
	// The server is interested in receiving didCreateFiles notifications.
	did_create: Maybe(FileOperationRegistrationOptions) `json:"didCreate,omitempty"`,
	// The server is interested in receiving willCreateFiles requests.
	will_create: Maybe(FileOperationRegistrationOptions) `json:"willCreate,omitempty"`,
	// The server is interested in receiving didRenameFiles notifications.
	did_rename: Maybe(FileOperationRegistrationOptions) `json:"didRename,omitempty"`,
	// The server is interested in receiving willRenameFiles requests.
	will_rename: Maybe(FileOperationRegistrationOptions) `json:"willRename,omitempty"`,
	// The server is interested in receiving didDeleteFiles file notifications.
	did_delete: Maybe(FileOperationRegistrationOptions) `json:"didDelete,omitempty"`,
	// The server is interested in receiving willDeleteFiles file requests.
	will_delete: Maybe(FileOperationRegistrationOptions) `json:"willDelete,omitempty"`,
}

// Structure to capture a description for an error code.
// 
// @since 3.16.0
CodeDescription :: struct {
	// An URI to open with more information about the diagnostic error.
	href: URI `json:"href"`,
}

// Represents a related message and source code location for a diagnostic. This should be
// used to point to code locations that cause or related to a diagnostics, e.g when duplicating
// a symbol in a scope.
DiagnosticRelatedInformation :: struct {
	// The location of this related diagnostic information.
	location: Location `json:"location"`,
	// The message of this related diagnostic information.
	message: string `json:"message"`,
}

// Represents a parameter of a callable-signature. A parameter can
// have a label and a doc-comment.
ParameterInformation :: struct {
	// The label of this parameter information.
	// 
	// Either a string or an inclusive start and exclusive end offsets within its containing
	// signature label. (see SignatureInformation.label). The offsets are based on a UTF-16
	// string representation as `Position` and `Range` does.
	// 
	// *Note*: a label of type string should be a substring of its containing signature label.
	// Its intended use case is to highlight the parameter label part in the `SignatureInformation.label`.
	label: union {string, [2]u32} `json:"label"`,
	// The human-readable doc-comment of this parameter. Will be shown
	// in the UI but can be omitted.
	documentation: Maybe(union {string, MarkupContent}) `json:"documentation,omitempty"`,
}

// A notebook cell text document filter denotes a cell text
// document by different properties.
// 
// @since 3.17.0
NotebookCellTextDocumentFilter :: struct {
	// A filter that matches against the notebook
	// containing the notebook cell. If a string
	// value is provided it matches against the
	// notebook type. '*' matches every notebook.
	notebook: union {string, NotebookDocumentFilter} `json:"notebook"`,
	// A language id like `python`.
	// 
	// Will be matched against the language id of the
	// notebook cell document. '*' matches every language.
	language: Maybe(string) `json:"language,omitempty"`,
}

// Matching options for the file operation pattern.
// 
// @since 3.16.0
FileOperationPatternOptions :: struct {
	// The pattern should be matched ignoring casing.
	ignore_case: Maybe(bool) `json:"ignoreCase,omitempty"`,
}

ExecutionSummary :: struct {
	// A strict monotonically increasing value
	// indicating the execution order of a cell
	// inside a notebook.
	execution_order: u32 `json:"executionOrder"`,
	// Whether the execution was successful or
	// not if known by the client.
	success: Maybe(bool) `json:"success,omitempty"`,
}

// Workspace specific client capabilities.
WorkspaceClientCapabilities :: struct {
	// The client supports applying batch edits
	// to the workspace by supporting the request
	// 'workspace/applyEdit'
	apply_edit: Maybe(bool) `json:"applyEdit,omitempty"`,
	// Capabilities specific to `WorkspaceEdit`s.
	workspace_edit: Maybe(WorkspaceEditClientCapabilities) `json:"workspaceEdit,omitempty"`,
	// Capabilities specific to the `workspace/didChangeConfiguration` notification.
	did_change_configuration: Maybe(DidChangeConfigurationClientCapabilities) `json:"didChangeConfiguration,omitempty"`,
	// Capabilities specific to the `workspace/didChangeWatchedFiles` notification.
	did_change_watched_files: Maybe(DidChangeWatchedFilesClientCapabilities) `json:"didChangeWatchedFiles,omitempty"`,
	// Capabilities specific to the `workspace/symbol` request.
	symbol: Maybe(WorkspaceSymbolClientCapabilities) `json:"symbol,omitempty"`,
	// Capabilities specific to the `workspace/executeCommand` request.
	execute_command: Maybe(ExecuteCommandClientCapabilities) `json:"executeCommand,omitempty"`,
	// The client has support for workspace folders.
	// 
	// @since 3.6.0
	workspace_folders: Maybe(bool) `json:"workspaceFolders,omitempty"`,
	// The client supports `workspace/configuration` requests.
	// 
	// @since 3.6.0
	configuration: Maybe(bool) `json:"configuration,omitempty"`,
	// Capabilities specific to the semantic token requests scoped to the
	// workspace.
	// 
	// @since 3.16.0.
	semantic_tokens: Maybe(SemanticTokensWorkspaceClientCapabilities) `json:"semanticTokens,omitempty"`,
	// Capabilities specific to the code lens requests scoped to the
	// workspace.
	// 
	// @since 3.16.0.
	code_lens: Maybe(CodeLensWorkspaceClientCapabilities) `json:"codeLens,omitempty"`,
	// The client has support for file notifications/requests for user operations on files.
	// 
	// Since 3.16.0
	file_operations: Maybe(FileOperationClientCapabilities) `json:"fileOperations,omitempty"`,
	// Capabilities specific to the inline values requests scoped to the
	// workspace.
	// 
	// @since 3.17.0.
	inline_value: Maybe(InlineValueWorkspaceClientCapabilities) `json:"inlineValue,omitempty"`,
	// Capabilities specific to the inlay hint requests scoped to the
	// workspace.
	// 
	// @since 3.17.0.
	inlay_hint: Maybe(InlayHintWorkspaceClientCapabilities) `json:"inlayHint,omitempty"`,
	// Capabilities specific to the diagnostic requests scoped to the
	// workspace.
	// 
	// @since 3.17.0.
	diagnostics: Maybe(DiagnosticWorkspaceClientCapabilities) `json:"diagnostics,omitempty"`,
	// Capabilities specific to the folding range requests scoped to the workspace.
	// 
	// @since 3.18.0
	// @proposed
	folding_range: Maybe(FoldingRangeWorkspaceClientCapabilities) `json:"foldingRange,omitempty"`,
}

// Text document specific client capabilities.
TextDocumentClientCapabilities :: struct {
	// Defines which synchronization capabilities the client supports.
	synchronization: Maybe(TextDocumentSyncClientCapabilities) `json:"synchronization,omitempty"`,
	// Capabilities specific to the `textDocument/completion` request.
	completion: Maybe(CompletionClientCapabilities) `json:"completion,omitempty"`,
	// Capabilities specific to the `textDocument/hover` request.
	hover: Maybe(HoverClientCapabilities) `json:"hover,omitempty"`,
	// Capabilities specific to the `textDocument/signatureHelp` request.
	signature_help: Maybe(SignatureHelpClientCapabilities) `json:"signatureHelp,omitempty"`,
	// Capabilities specific to the `textDocument/declaration` request.
	// 
	// @since 3.14.0
	declaration: Maybe(DeclarationClientCapabilities) `json:"declaration,omitempty"`,
	// Capabilities specific to the `textDocument/definition` request.
	definition: Maybe(DefinitionClientCapabilities) `json:"definition,omitempty"`,
	// Capabilities specific to the `textDocument/typeDefinition` request.
	// 
	// @since 3.6.0
	type_definition: Maybe(TypeDefinitionClientCapabilities) `json:"typeDefinition,omitempty"`,
	// Capabilities specific to the `textDocument/implementation` request.
	// 
	// @since 3.6.0
	implementation: Maybe(ImplementationClientCapabilities) `json:"implementation,omitempty"`,
	// Capabilities specific to the `textDocument/references` request.
	references: Maybe(ReferenceClientCapabilities) `json:"references,omitempty"`,
	// Capabilities specific to the `textDocument/documentHighlight` request.
	document_highlight: Maybe(DocumentHighlightClientCapabilities) `json:"documentHighlight,omitempty"`,
	// Capabilities specific to the `textDocument/documentSymbol` request.
	document_symbol: Maybe(DocumentSymbolClientCapabilities) `json:"documentSymbol,omitempty"`,
	// Capabilities specific to the `textDocument/codeAction` request.
	code_action: Maybe(CodeActionClientCapabilities) `json:"codeAction,omitempty"`,
	// Capabilities specific to the `textDocument/codeLens` request.
	code_lens: Maybe(CodeLensClientCapabilities) `json:"codeLens,omitempty"`,
	// Capabilities specific to the `textDocument/documentLink` request.
	document_link: Maybe(DocumentLinkClientCapabilities) `json:"documentLink,omitempty"`,
	// Capabilities specific to the `textDocument/documentColor` and the
	// `textDocument/colorPresentation` request.
	// 
	// @since 3.6.0
	color_provider: Maybe(DocumentColorClientCapabilities) `json:"colorProvider,omitempty"`,
	// Capabilities specific to the `textDocument/formatting` request.
	formatting: Maybe(DocumentFormattingClientCapabilities) `json:"formatting,omitempty"`,
	// Capabilities specific to the `textDocument/rangeFormatting` request.
	range_formatting: Maybe(DocumentRangeFormattingClientCapabilities) `json:"rangeFormatting,omitempty"`,
	// Capabilities specific to the `textDocument/onTypeFormatting` request.
	on_type_formatting: Maybe(DocumentOnTypeFormattingClientCapabilities) `json:"onTypeFormatting,omitempty"`,
	// Capabilities specific to the `textDocument/rename` request.
	rename: Maybe(RenameClientCapabilities) `json:"rename,omitempty"`,
	// Capabilities specific to the `textDocument/foldingRange` request.
	// 
	// @since 3.10.0
	folding_range: Maybe(FoldingRangeClientCapabilities) `json:"foldingRange,omitempty"`,
	// Capabilities specific to the `textDocument/selectionRange` request.
	// 
	// @since 3.15.0
	selection_range: Maybe(SelectionRangeClientCapabilities) `json:"selectionRange,omitempty"`,
	// Capabilities specific to the `textDocument/publishDiagnostics` notification.
	publish_diagnostics: Maybe(PublishDiagnosticsClientCapabilities) `json:"publishDiagnostics,omitempty"`,
	// Capabilities specific to the various call hierarchy requests.
	// 
	// @since 3.16.0
	call_hierarchy: Maybe(CallHierarchyClientCapabilities) `json:"callHierarchy,omitempty"`,
	// Capabilities specific to the various semantic token request.
	// 
	// @since 3.16.0
	semantic_tokens: Maybe(SemanticTokensClientCapabilities) `json:"semanticTokens,omitempty"`,
	// Capabilities specific to the `textDocument/linkedEditingRange` request.
	// 
	// @since 3.16.0
	linked_editing_range: Maybe(LinkedEditingRangeClientCapabilities) `json:"linkedEditingRange,omitempty"`,
	// Client capabilities specific to the `textDocument/moniker` request.
	// 
	// @since 3.16.0
	moniker: Maybe(MonikerClientCapabilities) `json:"moniker,omitempty"`,
	// Capabilities specific to the various type hierarchy requests.
	// 
	// @since 3.17.0
	type_hierarchy: Maybe(TypeHierarchyClientCapabilities) `json:"typeHierarchy,omitempty"`,
	// Capabilities specific to the `textDocument/inlineValue` request.
	// 
	// @since 3.17.0
	inline_value: Maybe(InlineValueClientCapabilities) `json:"inlineValue,omitempty"`,
	// Capabilities specific to the `textDocument/inlayHint` request.
	// 
	// @since 3.17.0
	inlay_hint: Maybe(InlayHintClientCapabilities) `json:"inlayHint,omitempty"`,
	// Capabilities specific to the diagnostic pull model.
	// 
	// @since 3.17.0
	diagnostic: Maybe(DiagnosticClientCapabilities) `json:"diagnostic,omitempty"`,
	// Client capabilities specific to inline completions.
	// 
	// @since 3.18.0
	// @proposed
	inline_completion: Maybe(InlineCompletionClientCapabilities) `json:"inlineCompletion,omitempty"`,
}

// Capabilities specific to the notebook document support.
// 
// @since 3.17.0
NotebookDocumentClientCapabilities :: struct {
	// Capabilities specific to notebook document synchronization
	// 
	// @since 3.17.0
	synchronization: NotebookDocumentSyncClientCapabilities `json:"synchronization"`,
}

WindowClientCapabilities :: struct {
	// It indicates whether the client supports server initiated
	// progress using the `window/workDoneProgress/create` request.
	// 
	// The capability also controls Whether client supports handling
	// of progress notifications. If set servers are allowed to report a
	// `workDoneProgress` property in the request specific server
	// capabilities.
	// 
	// @since 3.15.0
	work_done_progress: Maybe(bool) `json:"workDoneProgress,omitempty"`,
	// Capabilities specific to the showMessage request.
	// 
	// @since 3.16.0
	show_message: Maybe(ShowMessageRequestClientCapabilities) `json:"showMessage,omitempty"`,
	// Capabilities specific to the showDocument request.
	// 
	// @since 3.16.0
	show_document: Maybe(ShowDocumentClientCapabilities) `json:"showDocument,omitempty"`,
}

// General client capabilities.
// 
// @since 3.16.0
GeneralClientCapabilities :: struct {
	// Client capability that signals how the client
	// handles stale requests (e.g. a request
	// for which the client will not process the response
	// anymore since the information is outdated).
	// 
	// @since 3.17.0
	stale_request_support: Maybe(GeneralClientCapabilitiesStaleRequestSupport) `json:"staleRequestSupport,omitempty"`,
	// Client capabilities specific to regular expressions.
	// 
	// @since 3.16.0
	regular_expressions: Maybe(RegularExpressionsClientCapabilities) `json:"regularExpressions,omitempty"`,
	// Client capabilities specific to the client's markdown parser.
	// 
	// @since 3.16.0
	markdown: Maybe(MarkdownClientCapabilities) `json:"markdown,omitempty"`,
	// The position encodings supported by the client. Client and server
	// have to agree on the same position encoding to ensure that offsets
	// (e.g. character position in a line) are interpreted the same on both
	// sides.
	// 
	// To keep the protocol backwards compatible the following applies: if
	// the value 'utf-16' is missing from the array of position encodings
	// servers can assume that the client supports UTF-16. UTF-16 is
	// therefore a mandatory encoding.
	// 
	// If omitted it defaults to ['utf-16'].
	// 
	// Implementation considerations: since the conversion from one encoding
	// into another requires the content of the file / line the conversion
	// is best done where the file is read which is usually on the server
	// side.
	// 
	// @since 3.17.0
	position_encodings: Maybe([]PositionEncodingKind) `json:"positionEncodings,omitempty"`,
}

// A relative pattern is a helper to construct glob patterns that are matched
// relatively to a base URI. The common value for a `baseUri` is a workspace
// folder root, but it can be another absolute URI as well.
// 
// @since 3.17.0
RelativePattern :: struct {
	// A workspace folder or a base URI to which this pattern will be matched
	// against relatively.
	base_uri: union {WorkspaceFolder, URI} `json:"baseUri"`,
	// The actual glob pattern;
	pattern: Pattern `json:"pattern"`,
}

WorkspaceEditClientCapabilities :: struct {
	// The client supports versioned document changes in `WorkspaceEdit`s
	document_changes: Maybe(bool) `json:"documentChanges,omitempty"`,
	// The resource operations the client supports. Clients should at least
	// support 'create', 'rename' and 'delete' files and folders.
	// 
	// @since 3.13.0
	resource_operations: Maybe([]ResourceOperationKind) `json:"resourceOperations,omitempty"`,
	// The failure handling strategy of a client if applying the workspace edit
	// fails.
	// 
	// @since 3.13.0
	failure_handling: Maybe(FailureHandlingKind) `json:"failureHandling,omitempty"`,
	// Whether the client normalizes line endings to the client specific
	// setting.
	// If set to `true` the client will normalize line ending characters
	// in a workspace edit to the client-specified new line
	// character.
	// 
	// @since 3.16.0
	normalizes_line_endings: Maybe(bool) `json:"normalizesLineEndings,omitempty"`,
	// Whether the client in general supports change annotations on text edits,
	// create file, rename file and delete file changes.
	// 
	// @since 3.16.0
	change_annotation_support: Maybe(WorkspaceEditClientCapabilitiesChangeAnnotationSupport) `json:"changeAnnotationSupport,omitempty"`,
}

DidChangeConfigurationClientCapabilities :: struct {
	// Did change configuration notification supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

DidChangeWatchedFilesClientCapabilities :: struct {
	// Did change watched files notification supports dynamic registration. Please note
	// that the current protocol doesn't support static configuration for file changes
	// from the server side.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Whether the client has support for {@link  RelativePattern relative pattern}
	// or not.
	// 
	// @since 3.17.0
	relative_pattern_support: Maybe(bool) `json:"relativePatternSupport,omitempty"`,
}

// Client capabilities for a {@link WorkspaceSymbolRequest}.
WorkspaceSymbolClientCapabilities :: struct {
	// Symbol request supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Specific capabilities for the `SymbolKind` in the `workspace/symbol` request.
	symbol_kind: Maybe(WorkspaceSymbolClientCapabilitiesSymbolKind) `json:"symbolKind,omitempty"`,
	// The client supports tags on `SymbolInformation`.
	// Clients supporting tags have to handle unknown tags gracefully.
	// 
	// @since 3.16.0
	tag_support: Maybe(WorkspaceSymbolClientCapabilitiesTagSupport) `json:"tagSupport,omitempty"`,
	// The client support partial workspace symbols. The client will send the
	// request `workspaceSymbol/resolve` to the server to resolve additional
	// properties.
	// 
	// @since 3.17.0
	resolve_support: Maybe(WorkspaceSymbolClientCapabilitiesResolveSupport) `json:"resolveSupport,omitempty"`,
}

// The client capabilities of a {@link ExecuteCommandRequest}.
ExecuteCommandClientCapabilities :: struct {
	// Execute command supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// @since 3.16.0
SemanticTokensWorkspaceClientCapabilities :: struct {
	// Whether the client implementation supports a refresh request sent from
	// the server to the client.
	// 
	// Note that this event is global and will force the client to refresh all
	// semantic tokens currently shown. It should be used with absolute care
	// and is useful for situation where a server for example detects a project
	// wide change that requires such a calculation.
	refresh_support: Maybe(bool) `json:"refreshSupport,omitempty"`,
}

// @since 3.16.0
CodeLensWorkspaceClientCapabilities :: struct {
	// Whether the client implementation supports a refresh request sent from the
	// server to the client.
	// 
	// Note that this event is global and will force the client to refresh all
	// code lenses currently shown. It should be used with absolute care and is
	// useful for situation where a server for example detect a project wide
	// change that requires such a calculation.
	refresh_support: Maybe(bool) `json:"refreshSupport,omitempty"`,
}

// Capabilities relating to events from file operations by the user in the client.
// 
// These events do not come from the file system, they come from user operations
// like renaming a file in the UI.
// 
// @since 3.16.0
FileOperationClientCapabilities :: struct {
	// Whether the client supports dynamic registration for file requests/notifications.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client has support for sending didCreateFiles notifications.
	did_create: Maybe(bool) `json:"didCreate,omitempty"`,
	// The client has support for sending willCreateFiles requests.
	will_create: Maybe(bool) `json:"willCreate,omitempty"`,
	// The client has support for sending didRenameFiles notifications.
	did_rename: Maybe(bool) `json:"didRename,omitempty"`,
	// The client has support for sending willRenameFiles requests.
	will_rename: Maybe(bool) `json:"willRename,omitempty"`,
	// The client has support for sending didDeleteFiles notifications.
	did_delete: Maybe(bool) `json:"didDelete,omitempty"`,
	// The client has support for sending willDeleteFiles requests.
	will_delete: Maybe(bool) `json:"willDelete,omitempty"`,
}

// Client workspace capabilities specific to inline values.
// 
// @since 3.17.0
InlineValueWorkspaceClientCapabilities :: struct {
	// Whether the client implementation supports a refresh request sent from the
	// server to the client.
	// 
	// Note that this event is global and will force the client to refresh all
	// inline values currently shown. It should be used with absolute care and is
	// useful for situation where a server for example detects a project wide
	// change that requires such a calculation.
	refresh_support: Maybe(bool) `json:"refreshSupport,omitempty"`,
}

// Client workspace capabilities specific to inlay hints.
// 
// @since 3.17.0
InlayHintWorkspaceClientCapabilities :: struct {
	// Whether the client implementation supports a refresh request sent from
	// the server to the client.
	// 
	// Note that this event is global and will force the client to refresh all
	// inlay hints currently shown. It should be used with absolute care and
	// is useful for situation where a server for example detects a project wide
	// change that requires such a calculation.
	refresh_support: Maybe(bool) `json:"refreshSupport,omitempty"`,
}

// Workspace client capabilities specific to diagnostic pull requests.
// 
// @since 3.17.0
DiagnosticWorkspaceClientCapabilities :: struct {
	// Whether the client implementation supports a refresh request sent from
	// the server to the client.
	// 
	// Note that this event is global and will force the client to refresh all
	// pulled diagnostics currently shown. It should be used with absolute care and
	// is useful for situation where a server for example detects a project wide
	// change that requires such a calculation.
	refresh_support: Maybe(bool) `json:"refreshSupport,omitempty"`,
}

// Client workspace capabilities specific to folding ranges
// 
// @since 3.18.0
// @proposed
FoldingRangeWorkspaceClientCapabilities :: struct {
	// Whether the client implementation supports a refresh request sent from the
	// server to the client.
	// 
	// Note that this event is global and will force the client to refresh all
	// folding ranges currently shown. It should be used with absolute care and is
	// useful for situation where a server for example detects a project wide
	// change that requires such a calculation.
	// 
	// @since 3.18.0
	// @proposed
	refresh_support: Maybe(bool) `json:"refreshSupport,omitempty"`,
}

TextDocumentSyncClientCapabilities :: struct {
	// Whether text document synchronization supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports sending will save notifications.
	will_save: Maybe(bool) `json:"willSave,omitempty"`,
	// The client supports sending a will save request and
	// waits for a response providing text edits which will
	// be applied to the document before it is saved.
	will_save_wait_until: Maybe(bool) `json:"willSaveWaitUntil,omitempty"`,
	// The client supports did save notifications.
	did_save: Maybe(bool) `json:"didSave,omitempty"`,
}

// Completion client capabilities
CompletionClientCapabilities :: struct {
	// Whether completion supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports the following `CompletionItem` specific
	// capabilities.
	completion_item: Maybe(CompletionClientCapabilitiesCompletionItem) `json:"completionItem,omitempty"`,
	completion_item_kind: Maybe(CompletionClientCapabilitiesCompletionItemKind) `json:"completionItemKind,omitempty"`,
	// Defines how the client handles whitespace and indentation
	// when accepting a completion item that uses multi line
	// text in either `insertText` or `textEdit`.
	// 
	// @since 3.17.0
	insert_text_mode: Maybe(InsertTextMode) `json:"insertTextMode,omitempty"`,
	// The client supports to send additional context information for a
	// `textDocument/completion` request.
	context_support: Maybe(bool) `json:"contextSupport,omitempty"`,
	// The client supports the following `CompletionList` specific
	// capabilities.
	// 
	// @since 3.17.0
	completion_list: Maybe(CompletionClientCapabilitiesCompletionList) `json:"completionList,omitempty"`,
}

HoverClientCapabilities :: struct {
	// Whether hover supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Client supports the following content formats for the content
	// property. The order describes the preferred format of the client.
	content_format: Maybe([]MarkupKind) `json:"contentFormat,omitempty"`,
}

// Client Capabilities for a {@link SignatureHelpRequest}.
SignatureHelpClientCapabilities :: struct {
	// Whether signature help supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports the following `SignatureInformation`
	// specific properties.
	signature_information: Maybe(SignatureHelpClientCapabilitiesSignatureInformation) `json:"signatureInformation,omitempty"`,
	// The client supports to send additional context information for a
	// `textDocument/signatureHelp` request. A client that opts into
	// contextSupport will also support the `retriggerCharacters` on
	// `SignatureHelpOptions`.
	// 
	// @since 3.15.0
	context_support: Maybe(bool) `json:"contextSupport,omitempty"`,
}

// @since 3.14.0
DeclarationClientCapabilities :: struct {
	// Whether declaration supports dynamic registration. If this is set to `true`
	// the client supports the new `DeclarationRegistrationOptions` return value
	// for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports additional metadata in the form of declaration links.
	link_support: Maybe(bool) `json:"linkSupport,omitempty"`,
}

// Client Capabilities for a {@link DefinitionRequest}.
DefinitionClientCapabilities :: struct {
	// Whether definition supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports additional metadata in the form of definition links.
	// 
	// @since 3.14.0
	link_support: Maybe(bool) `json:"linkSupport,omitempty"`,
}

// Since 3.6.0
TypeDefinitionClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `TypeDefinitionRegistrationOptions` return value
	// for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports additional metadata in the form of definition links.
	// 
	// Since 3.14.0
	link_support: Maybe(bool) `json:"linkSupport,omitempty"`,
}

// @since 3.6.0
ImplementationClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `ImplementationRegistrationOptions` return value
	// for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports additional metadata in the form of definition links.
	// 
	// @since 3.14.0
	link_support: Maybe(bool) `json:"linkSupport,omitempty"`,
}

// Client Capabilities for a {@link ReferencesRequest}.
ReferenceClientCapabilities :: struct {
	// Whether references supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Client Capabilities for a {@link DocumentHighlightRequest}.
DocumentHighlightClientCapabilities :: struct {
	// Whether document highlight supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Client Capabilities for a {@link DocumentSymbolRequest}.
DocumentSymbolClientCapabilities :: struct {
	// Whether document symbol supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Specific capabilities for the `SymbolKind` in the
	// `textDocument/documentSymbol` request.
	symbol_kind: Maybe(DocumentSymbolClientCapabilitiesSymbolKind) `json:"symbolKind,omitempty"`,
	// The client supports hierarchical document symbols.
	hierarchical_document_symbol_support: Maybe(bool) `json:"hierarchicalDocumentSymbolSupport,omitempty"`,
	// The client supports tags on `SymbolInformation`. Tags are supported on
	// `DocumentSymbol` if `hierarchicalDocumentSymbolSupport` is set to true.
	// Clients supporting tags have to handle unknown tags gracefully.
	// 
	// @since 3.16.0
	tag_support: Maybe(DocumentSymbolClientCapabilitiesTagSupport) `json:"tagSupport,omitempty"`,
	// The client supports an additional label presented in the UI when
	// registering a document symbol provider.
	// 
	// @since 3.16.0
	label_support: Maybe(bool) `json:"labelSupport,omitempty"`,
}

// The Client Capabilities of a {@link CodeActionRequest}.
CodeActionClientCapabilities :: struct {
	// Whether code action supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client support code action literals of type `CodeAction` as a valid
	// response of the `textDocument/codeAction` request. If the property is not
	// set the request can only return `Command` literals.
	// 
	// @since 3.8.0
	code_action_literal_support: Maybe(CodeActionClientCapabilitiesCodeActionLiteralSupport) `json:"codeActionLiteralSupport,omitempty"`,
	// Whether code action supports the `isPreferred` property.
	// 
	// @since 3.15.0
	is_preferred_support: Maybe(bool) `json:"isPreferredSupport,omitempty"`,
	// Whether code action supports the `disabled` property.
	// 
	// @since 3.16.0
	disabled_support: Maybe(bool) `json:"disabledSupport,omitempty"`,
	// Whether code action supports the `data` property which is
	// preserved between a `textDocument/codeAction` and a
	// `codeAction/resolve` request.
	// 
	// @since 3.16.0
	data_support: Maybe(bool) `json:"dataSupport,omitempty"`,
	// Whether the client supports resolving additional code action
	// properties via a separate `codeAction/resolve` request.
	// 
	// @since 3.16.0
	resolve_support: Maybe(CodeActionClientCapabilitiesResolveSupport) `json:"resolveSupport,omitempty"`,
	// Whether the client honors the change annotations in
	// text edits and resource operations returned via the
	// `CodeAction#edit` property by for example presenting
	// the workspace edit in the user interface and asking
	// for confirmation.
	// 
	// @since 3.16.0
	honors_change_annotations: Maybe(bool) `json:"honorsChangeAnnotations,omitempty"`,
}

// The client capabilities  of a {@link CodeLensRequest}.
CodeLensClientCapabilities :: struct {
	// Whether code lens supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// The client capabilities of a {@link DocumentLinkRequest}.
DocumentLinkClientCapabilities :: struct {
	// Whether document link supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Whether the client supports the `tooltip` property on `DocumentLink`.
	// 
	// @since 3.15.0
	tooltip_support: Maybe(bool) `json:"tooltipSupport,omitempty"`,
}

DocumentColorClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `DocumentColorRegistrationOptions` return value
	// for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Client capabilities of a {@link DocumentFormattingRequest}.
DocumentFormattingClientCapabilities :: struct {
	// Whether formatting supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Client capabilities of a {@link DocumentRangeFormattingRequest}.
DocumentRangeFormattingClientCapabilities :: struct {
	// Whether range formatting supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Whether the client supports formatting multiple ranges at once.
	// 
	// @since 3.18.0
	// @proposed
	ranges_support: Maybe(bool) `json:"rangesSupport,omitempty"`,
}

// Client capabilities of a {@link DocumentOnTypeFormattingRequest}.
DocumentOnTypeFormattingClientCapabilities :: struct {
	// Whether on type formatting supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

RenameClientCapabilities :: struct {
	// Whether rename supports dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Client supports testing for validity of rename operations
	// before execution.
	// 
	// @since 3.12.0
	prepare_support: Maybe(bool) `json:"prepareSupport,omitempty"`,
	// Client supports the default behavior result.
	// 
	// The value indicates the default behavior used by the
	// client.
	// 
	// @since 3.16.0
	prepare_support_default_behavior: Maybe(PrepareSupportDefaultBehavior) `json:"prepareSupportDefaultBehavior,omitempty"`,
	// Whether the client honors the change annotations in
	// text edits and resource operations returned via the
	// rename request's workspace edit by for example presenting
	// the workspace edit in the user interface and asking
	// for confirmation.
	// 
	// @since 3.16.0
	honors_change_annotations: Maybe(bool) `json:"honorsChangeAnnotations,omitempty"`,
}

FoldingRangeClientCapabilities :: struct {
	// Whether implementation supports dynamic registration for folding range
	// providers. If this is set to `true` the client supports the new
	// `FoldingRangeRegistrationOptions` return value for the corresponding
	// server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The maximum number of folding ranges that the client prefers to receive
	// per document. The value serves as a hint, servers are free to follow the
	// limit.
	range_limit: Maybe(u32) `json:"rangeLimit,omitempty"`,
	// If set, the client signals that it only supports folding complete lines.
	// If set, client will ignore specified `startCharacter` and `endCharacter`
	// properties in a FoldingRange.
	line_folding_only: Maybe(bool) `json:"lineFoldingOnly,omitempty"`,
	// Specific options for the folding range kind.
	// 
	// @since 3.17.0
	folding_range_kind: Maybe(FoldingRangeClientCapabilitiesFoldingRangeKind) `json:"foldingRangeKind,omitempty"`,
	// Specific options for the folding range.
	// 
	// @since 3.17.0
	folding_range: Maybe(FoldingRangeClientCapabilitiesFoldingRange) `json:"foldingRange,omitempty"`,
}

SelectionRangeClientCapabilities :: struct {
	// Whether implementation supports dynamic registration for selection range providers. If this is set to `true`
	// the client supports the new `SelectionRangeRegistrationOptions` return value for the corresponding server
	// capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// The publish diagnostic client capabilities.
PublishDiagnosticsClientCapabilities :: struct {
	// Whether the clients accepts diagnostics with related information.
	related_information: Maybe(bool) `json:"relatedInformation,omitempty"`,
	// Client supports the tag property to provide meta data about a diagnostic.
	// Clients supporting tags have to handle unknown tags gracefully.
	// 
	// @since 3.15.0
	tag_support: Maybe(PublishDiagnosticsClientCapabilitiesTagSupport) `json:"tagSupport,omitempty"`,
	// Whether the client interprets the version property of the
	// `textDocument/publishDiagnostics` notification's parameter.
	// 
	// @since 3.15.0
	version_support: Maybe(bool) `json:"versionSupport,omitempty"`,
	// Client supports a codeDescription property
	// 
	// @since 3.16.0
	code_description_support: Maybe(bool) `json:"codeDescriptionSupport,omitempty"`,
	// Whether code action supports the `data` property which is
	// preserved between a `textDocument/publishDiagnostics` and
	// `textDocument/codeAction` request.
	// 
	// @since 3.16.0
	data_support: Maybe(bool) `json:"dataSupport,omitempty"`,
}

// @since 3.16.0
CallHierarchyClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	// return value for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// @since 3.16.0
SemanticTokensClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	// return value for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Which requests the client supports and might send to the server
	// depending on the server's capability. Please note that clients might not
	// show semantic tokens or degrade some of the user experience if a range
	// or full request is advertised by the client but not provided by the
	// server. If for example the client capability `requests.full` and
	// `request.range` are both set to true but the server only provides a
	// range provider the client might not render a minimap correctly or might
	// even decide to not show any semantic tokens at all.
	requests: SemanticTokensClientCapabilitiesRequests `json:"requests"`,
	// The token types that the client supports.
	token_types: []string `json:"tokenTypes"`,
	// The token modifiers that the client supports.
	token_modifiers: []string `json:"tokenModifiers"`,
	// The token formats the clients supports.
	formats: []TokenFormat `json:"formats"`,
	// Whether the client supports tokens that can overlap each other.
	overlapping_token_support: Maybe(bool) `json:"overlappingTokenSupport,omitempty"`,
	// Whether the client supports tokens that can span multiple lines.
	multiline_token_support: Maybe(bool) `json:"multilineTokenSupport,omitempty"`,
	// Whether the client allows the server to actively cancel a
	// semantic token request, e.g. supports returning
	// LSPErrorCodes.ServerCancelled. If a server does the client
	// needs to retrigger the request.
	// 
	// @since 3.17.0
	server_cancel_support: Maybe(bool) `json:"serverCancelSupport,omitempty"`,
	// Whether the client uses semantic tokens to augment existing
	// syntax tokens. If set to `true` client side created syntax
	// tokens and semantic tokens are both used for colorization. If
	// set to `false` the client only uses the returned semantic tokens
	// for colorization.
	// 
	// If the value is `undefined` then the client behavior is not
	// specified.
	// 
	// @since 3.17.0
	augments_syntax_tokens: Maybe(bool) `json:"augmentsSyntaxTokens,omitempty"`,
}

// Client capabilities for the linked editing range request.
// 
// @since 3.16.0
LinkedEditingRangeClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	// return value for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Client capabilities specific to the moniker request.
// 
// @since 3.16.0
MonikerClientCapabilities :: struct {
	// Whether moniker supports dynamic registration. If this is set to `true`
	// the client supports the new `MonikerRegistrationOptions` return value
	// for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// @since 3.17.0
TypeHierarchyClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	// return value for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Client capabilities specific to inline values.
// 
// @since 3.17.0
InlineValueClientCapabilities :: struct {
	// Whether implementation supports dynamic registration for inline value providers.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Inlay hint client capabilities.
// 
// @since 3.17.0
InlayHintClientCapabilities :: struct {
	// Whether inlay hints support dynamic registration.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Indicates which properties a client can resolve lazily on an inlay
	// hint.
	resolve_support: Maybe(InlayHintClientCapabilitiesResolveSupport) `json:"resolveSupport,omitempty"`,
}

// Client capabilities specific to diagnostic pull requests.
// 
// @since 3.17.0
DiagnosticClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is set to `true`
	// the client supports the new `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	// return value for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// Whether the clients supports related documents for document diagnostic pulls.
	related_document_support: Maybe(bool) `json:"relatedDocumentSupport,omitempty"`,
}

// Client capabilities specific to inline completions.
// 
// @since 3.18.0
// @proposed
InlineCompletionClientCapabilities :: struct {
	// Whether implementation supports dynamic registration for inline completion providers.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
}

// Notebook specific client capabilities.
// 
// @since 3.17.0
NotebookDocumentSyncClientCapabilities :: struct {
	// Whether implementation supports dynamic registration. If this is
	// set to `true` the client supports the new
	// `(TextDocumentRegistrationOptions & StaticRegistrationOptions)`
	// return value for the corresponding server capability as well.
	dynamic_registration: Maybe(bool) `json:"dynamicRegistration,omitempty"`,
	// The client supports sending execution summary data per cell.
	execution_summary_support: Maybe(bool) `json:"executionSummarySupport,omitempty"`,
}

// Show message request client capabilities
ShowMessageRequestClientCapabilities :: struct {
	// Capabilities specific to the `MessageActionItem` type.
	message_action_item: Maybe(ShowMessageRequestClientCapabilitiesMessageActionItem) `json:"messageActionItem,omitempty"`,
}

// Client capabilities for the showDocument request.
// 
// @since 3.16.0
ShowDocumentClientCapabilities :: struct {
	// The client has support for the showDocument
	// request.
	support: bool `json:"support"`,
}

// Client capabilities specific to regular expressions.
// 
// @since 3.16.0
RegularExpressionsClientCapabilities :: struct {
	// The engine's name.
	engine: string `json:"engine"`,
	// The engine's version.
	version: Maybe(string) `json:"version,omitempty"`,
}

// Client capabilities specific to the used markdown parser.
// 
// @since 3.16.0
MarkdownClientCapabilities :: struct {
	// The name of the parser.
	parser: string `json:"parser"`,
	// The version of the parser.
	version: Maybe(string) `json:"version,omitempty"`,
	// A list of HTML tags that the client allows / supports in
	// Markdown.
	// 
	// @since 3.17.0
	allowed_tags: Maybe([]string) `json:"allowedTags,omitempty"`,
}

// Requests & notifications

Method :: enum {
	// A request to resolve the implementation locations of a symbol at a given text
	// document position. The request's parameter is of type {@link TextDocumentPositionParams}
	// the response is of type {@link Definition} or a Thenable that resolves to such.
	TextDocument_Implementation,
	// A request to resolve the type definition locations of a symbol at a given text
	// document position. The request's parameter is of type {@link TextDocumentPositionParams}
	// the response is of type {@link Definition} or a Thenable that resolves to such.
	TextDocument_TypeDefinition,
	// The `workspace/workspaceFolders` is sent from the server to the client to fetch the open workspace folders.
	Workspace_WorkspaceFolders,
	// The 'workspace/configuration' request is sent from the server to the client to fetch a certain
	// configuration setting.
	// 
	// This pull model replaces the old push model where the client signaled configuration change via an
	// event. If the server still needs to react to configuration changes (since the server caches the
	// result of `workspace/configuration` requests) the server should register for an empty configuration
	// change event and empty the cache if such an event is received.
	Workspace_Configuration,
	// A request to list all color symbols found in a given text document. The request's
	// parameter is of type {@link DocumentColorParams} the
	// response is of type {@link ColorInformation ColorInformation[]} or a Thenable
	// that resolves to such.
	TextDocument_DocumentColor,
	// A request to list all presentation for a color. The request's
	// parameter is of type {@link ColorPresentationParams} the
	// response is of type {@link ColorInformation ColorInformation[]} or a Thenable
	// that resolves to such.
	TextDocument_ColorPresentation,
	// A request to provide folding ranges in a document. The request's
	// parameter is of type {@link FoldingRangeParams}, the
	// response is of type {@link FoldingRangeList} or a Thenable
	// that resolves to such.
	TextDocument_FoldingRange,
	// @since 3.18.0
	// @proposed
	Workspace_FoldingRange_Refresh,
	// A request to resolve the type definition locations of a symbol at a given text
	// document position. The request's parameter is of type {@link TextDocumentPositionParams}
	// the response is of type {@link Declaration} or a typed array of {@link DeclarationLink}
	// or a Thenable that resolves to such.
	TextDocument_Declaration,
	// A request to provide selection ranges in a document. The request's
	// parameter is of type {@link SelectionRangeParams}, the
	// response is of type {@link SelectionRange SelectionRange[]} or a Thenable
	// that resolves to such.
	TextDocument_SelectionRange,
	// The `window/workDoneProgress/create` request is sent from the server to the client to initiate progress
	// reporting from the server.
	Window_WorkDoneProgress_Create,
	// A request to result a `CallHierarchyItem` in a document at a given position.
	// Can be used as an input to an incoming or outgoing call hierarchy.
	// 
	// @since 3.16.0
	TextDocument_PrepareCallHierarchy,
	// A request to resolve the incoming calls for a given `CallHierarchyItem`.
	// 
	// @since 3.16.0
	CallHierarchy_IncomingCalls,
	// A request to resolve the outgoing calls for a given `CallHierarchyItem`.
	// 
	// @since 3.16.0
	CallHierarchy_OutgoingCalls,
	// @since 3.16.0
	TextDocument_SemanticTokens_Full,
	// @since 3.16.0
	TextDocument_SemanticTokens_Full_Delta,
	// @since 3.16.0
	TextDocument_SemanticTokens_Range,
	// @since 3.16.0
	Workspace_SemanticTokens_Refresh,
	// A request to show a document. This request might open an
	// external program depending on the value of the URI to open.
	// For example a request to open `https://code.visualstudio.com/`
	// will very likely open the URI in a WEB browser.
	// 
	// @since 3.16.0
	Window_ShowDocument,
	// A request to provide ranges that can be edited together.
	// 
	// @since 3.16.0
	TextDocument_LinkedEditingRange,
	// The will create files request is sent from the client to the server before files are actually
	// created as long as the creation is triggered from within the client.
	// 
	// The request can return a `WorkspaceEdit` which will be applied to workspace before the
	// files are created. Hence the `WorkspaceEdit` can not manipulate the content of the file
	// to be created.
	// 
	// @since 3.16.0
	Workspace_WillCreateFiles,
	// The will rename files request is sent from the client to the server before files are actually
	// renamed as long as the rename is triggered from within the client.
	// 
	// @since 3.16.0
	Workspace_WillRenameFiles,
	// The did delete files notification is sent from the client to the server when
	// files were deleted from within the client.
	// 
	// @since 3.16.0
	Workspace_WillDeleteFiles,
	// A request to get the moniker of a symbol at a given text document position.
	// The request parameter is of type {@link TextDocumentPositionParams}.
	// The response is of type {@link Moniker Moniker[]} or `null`.
	TextDocument_Moniker,
	// A request to result a `TypeHierarchyItem` in a document at a given position.
	// Can be used as an input to a subtypes or supertypes type hierarchy.
	// 
	// @since 3.17.0
	TextDocument_PrepareTypeHierarchy,
	// A request to resolve the supertypes for a given `TypeHierarchyItem`.
	// 
	// @since 3.17.0
	TypeHierarchy_Supertypes,
	// A request to resolve the subtypes for a given `TypeHierarchyItem`.
	// 
	// @since 3.17.0
	TypeHierarchy_Subtypes,
	// A request to provide inline values in a document. The request's parameter is of
	// type {@link InlineValueParams}, the response is of type
	// {@link InlineValue InlineValue[]} or a Thenable that resolves to such.
	// 
	// @since 3.17.0
	TextDocument_InlineValue,
	// @since 3.17.0
	Workspace_InlineValue_Refresh,
	// A request to provide inlay hints in a document. The request's parameter is of
	// type {@link InlayHintsParams}, the response is of type
	// {@link InlayHint InlayHint[]} or a Thenable that resolves to such.
	// 
	// @since 3.17.0
	TextDocument_InlayHint,
	// A request to resolve additional properties for an inlay hint.
	// The request's parameter is of type {@link InlayHint}, the response is
	// of type {@link InlayHint} or a Thenable that resolves to such.
	// 
	// @since 3.17.0
	InlayHint_Resolve,
	// @since 3.17.0
	Workspace_InlayHint_Refresh,
	// The document diagnostic request definition.
	// 
	// @since 3.17.0
	TextDocument_Diagnostic,
	// The workspace diagnostic request definition.
	// 
	// @since 3.17.0
	Workspace_Diagnostic,
	// The diagnostic refresh request definition.
	// 
	// @since 3.17.0
	Workspace_Diagnostic_Refresh,
	// A request to provide inline completions in a document. The request's parameter is of
	// type {@link InlineCompletionParams}, the response is of type
	// {@link InlineCompletion InlineCompletion[]} or a Thenable that resolves to such.
	// 
	// @since 3.18.0
	// @proposed
	TextDocument_InlineCompletion,
	// The `client/registerCapability` request is sent from the server to the client to register a new capability
	// handler on the client side.
	Client_RegisterCapability,
	// The `client/unregisterCapability` request is sent from the server to the client to unregister a previously registered capability
	// handler on the client side.
	Client_UnregisterCapability,
	// The initialize request is sent from the client to the server.
	// It is sent once as the request after starting up the server.
	// The requests parameter is of type {@link InitializeParams}
	// the response if of type {@link InitializeResult} of a Thenable that
	// resolves to such.
	Initialize,
	// A shutdown request is sent from the client to the server.
	// It is sent once when the client decides to shutdown the
	// server. The only notification that is sent after a shutdown request
	// is the exit event.
	Shutdown,
	// The show message request is sent from the server to the client to show a message
	// and a set of options actions to the user.
	Window_ShowMessageRequest,
	// A document will save request is sent from the client to the server before
	// the document is actually saved. The request can return an array of TextEdits
	// which will be applied to the text document before it is saved. Please note that
	// clients might drop results if computing the text edits took too long or if a
	// server constantly fails on this request. This is done to keep the save fast and
	// reliable.
	TextDocument_WillSaveWaitUntil,
	// Request to request completion at a given text document position. The request's
	// parameter is of type {@link TextDocumentPosition} the response
	// is of type {@link CompletionItem CompletionItem[]} or {@link CompletionList}
	// or a Thenable that resolves to such.
	// 
	// The request can delay the computation of the {@link CompletionItem.detail `detail`}
	// and {@link CompletionItem.documentation `documentation`} properties to the `completionItem/resolve`
	// request. However, properties that are needed for the initial sorting and filtering, like `sortText`,
	// `filterText`, `insertText`, and `textEdit`, must not be changed during resolve.
	TextDocument_Completion,
	// Request to resolve additional information for a given completion item.The request's
	// parameter is of type {@link CompletionItem} the response
	// is of type {@link CompletionItem} or a Thenable that resolves to such.
	CompletionItem_Resolve,
	// Request to request hover information at a given text document position. The request's
	// parameter is of type {@link TextDocumentPosition} the response is of
	// type {@link Hover} or a Thenable that resolves to such.
	TextDocument_Hover,
	TextDocument_SignatureHelp,
	// A request to resolve the definition location of a symbol at a given text
	// document position. The request's parameter is of type {@link TextDocumentPosition}
	// the response is of either type {@link Definition} or a typed array of
	// {@link DefinitionLink} or a Thenable that resolves to such.
	TextDocument_Definition,
	// A request to resolve project-wide references for the symbol denoted
	// by the given text document position. The request's parameter is of
	// type {@link ReferenceParams} the response is of type
	// {@link Location Location[]} or a Thenable that resolves to such.
	TextDocument_References,
	// Request to resolve a {@link DocumentHighlight} for a given
	// text document position. The request's parameter is of type {@link TextDocumentPosition}
	// the request response is an array of type {@link DocumentHighlight}
	// or a Thenable that resolves to such.
	TextDocument_DocumentHighlight,
	// A request to list all symbols found in a given text document. The request's
	// parameter is of type {@link TextDocumentIdentifier} the
	// response is of type {@link SymbolInformation SymbolInformation[]} or a Thenable
	// that resolves to such.
	TextDocument_DocumentSymbol,
	// A request to provide commands for the given text document and range.
	TextDocument_CodeAction,
	// Request to resolve additional information for a given code action.The request's
	// parameter is of type {@link CodeAction} the response
	// is of type {@link CodeAction} or a Thenable that resolves to such.
	CodeAction_Resolve,
	// A request to list project-wide symbols matching the query string given
	// by the {@link WorkspaceSymbolParams}. The response is
	// of type {@link SymbolInformation SymbolInformation[]} or a Thenable that
	// resolves to such.
	// 
	// @since 3.17.0 - support for WorkspaceSymbol in the returned data. Clients
	//  need to advertise support for WorkspaceSymbols via the client capability
	//  `workspace.symbol.resolveSupport`.
	Workspace_Symbol,
	// A request to resolve the range inside the workspace
	// symbol's location.
	// 
	// @since 3.17.0
	WorkspaceSymbol_Resolve,
	// A request to provide code lens for the given text document.
	TextDocument_CodeLens,
	// A request to resolve a command for a given code lens.
	CodeLens_Resolve,
	// A request to refresh all code actions
	// 
	// @since 3.16.0
	Workspace_CodeLens_Refresh,
	// A request to provide document links
	TextDocument_DocumentLink,
	// Request to resolve additional information for a given document link. The request's
	// parameter is of type {@link DocumentLink} the response
	// is of type {@link DocumentLink} or a Thenable that resolves to such.
	DocumentLink_Resolve,
	// A request to format a whole document.
	TextDocument_Formatting,
	// A request to format a range in a document.
	TextDocument_RangeFormatting,
	// A request to format ranges in a document.
	// 
	// @since 3.18.0
	// @proposed
	TextDocument_RangesFormatting,
	// A request to format a document on type.
	TextDocument_OnTypeFormatting,
	// A request to rename a symbol.
	TextDocument_Rename,
	// A request to test and perform the setup necessary for a rename.
	// 
	// @since 3.16 - support for default behavior
	TextDocument_PrepareRename,
	// A request send from the client to the server to execute a command. The request might return
	// a workspace edit which the client will apply to the workspace.
	Workspace_ExecuteCommand,
	// A request sent from the server to the client to modified certain resources.
	Workspace_ApplyEdit,
	// The `workspace/didChangeWorkspaceFolders` notification is sent from the client to the server when the workspace
	// folder configuration changes.
	Workspace_DidChangeWorkspaceFolders,
	// The `window/workDoneProgress/cancel` notification is sent from  the client to the server to cancel a progress
	// initiated on the server side.
	Window_WorkDoneProgress_Cancel,
	// The did create files notification is sent from the client to the server when
	// files were created from within the client.
	// 
	// @since 3.16.0
	Workspace_DidCreateFiles,
	// The did rename files notification is sent from the client to the server when
	// files were renamed from within the client.
	// 
	// @since 3.16.0
	Workspace_DidRenameFiles,
	// The will delete files request is sent from the client to the server before files are actually
	// deleted as long as the deletion is triggered from within the client.
	// 
	// @since 3.16.0
	Workspace_DidDeleteFiles,
	// A notification sent when a notebook opens.
	// 
	// @since 3.17.0
	NotebookDocument_DidOpen,
	NotebookDocument_DidChange,
	// A notification sent when a notebook document is saved.
	// 
	// @since 3.17.0
	NotebookDocument_DidSave,
	// A notification sent when a notebook closes.
	// 
	// @since 3.17.0
	NotebookDocument_DidClose,
	// The initialized notification is sent from the client to the
	// server after the client is fully initialized and the server
	// is allowed to send requests from the server to the client.
	Initialized,
	// The exit event is sent from the client to the server to
	// ask the server to exit its process.
	Exit,
	// The configuration change notification is sent from the client to the server
	// when the client's configuration has changed. The notification contains
	// the changed configuration as defined by the language client.
	Workspace_DidChangeConfiguration,
	// The show message notification is sent from a server to a client to ask
	// the client to display a particular message in the user interface.
	Window_ShowMessage,
	// The log message notification is sent from the server to the client to ask
	// the client to log a particular message.
	Window_LogMessage,
	// The telemetry event notification is sent from the server to the client to ask
	// the client to log telemetry data.
	Telemetry_Event,
	// The document open notification is sent from the client to the server to signal
	// newly opened text documents. The document's truth is now managed by the client
	// and the server must not try to read the document's truth using the document's
	// uri. Open in this sense means it is managed by the client. It doesn't necessarily
	// mean that its content is presented in an editor. An open notification must not
	// be sent more than once without a corresponding close notification send before.
	// This means open and close notification must be balanced and the max open count
	// is one.
	TextDocument_DidOpen,
	// The document change notification is sent from the client to the server to signal
	// changes to a text document.
	TextDocument_DidChange,
	// The document close notification is sent from the client to the server when
	// the document got closed in the client. The document's truth now exists where
	// the document's uri points to (e.g. if the document's uri is a file uri the
	// truth now exists on disk). As with the open notification the close notification
	// is about managing the document's content. Receiving a close notification
	// doesn't mean that the document was open in an editor before. A close
	// notification requires a previous open notification to be sent.
	TextDocument_DidClose,
	// The document save notification is sent from the client to the server when
	// the document got saved in the client.
	TextDocument_DidSave,
	// A document will save notification is sent from the client to the server before
	// the document is actually saved.
	TextDocument_WillSave,
	// The watched files notification is sent from the client to the server when
	// the client detects changes to file watched by the language client.
	Workspace_DidChangeWatchedFiles,
	// Diagnostics notification are sent from the server to the client to signal
	// results of validation runs.
	TextDocument_PublishDiagnostics,
	Dollar_SetTrace,
	Dollar_LogTrace,
	Dollar_CancelRequest,
	Dollar_Progress,
}

Message_Info :: struct {
	method:          string,
	is_notification: bool,
	params_type:     typeid,
	result_type:     typeid,
}

method_string := [Method]string{
	.TextDocument_Implementation = "textDocument/implementation",
	.TextDocument_TypeDefinition = "textDocument/typeDefinition",
	.Workspace_WorkspaceFolders = "workspace/workspaceFolders",
	.Workspace_Configuration = "workspace/configuration",
	.TextDocument_DocumentColor = "textDocument/documentColor",
	.TextDocument_ColorPresentation = "textDocument/colorPresentation",
	.TextDocument_FoldingRange = "textDocument/foldingRange",
	.Workspace_FoldingRange_Refresh = "workspace/foldingRange/refresh",
	.TextDocument_Declaration = "textDocument/declaration",
	.TextDocument_SelectionRange = "textDocument/selectionRange",
	.Window_WorkDoneProgress_Create = "window/workDoneProgress/create",
	.TextDocument_PrepareCallHierarchy = "textDocument/prepareCallHierarchy",
	.CallHierarchy_IncomingCalls = "callHierarchy/incomingCalls",
	.CallHierarchy_OutgoingCalls = "callHierarchy/outgoingCalls",
	.TextDocument_SemanticTokens_Full = "textDocument/semanticTokens/full",
	.TextDocument_SemanticTokens_Full_Delta = "textDocument/semanticTokens/full/delta",
	.TextDocument_SemanticTokens_Range = "textDocument/semanticTokens/range",
	.Workspace_SemanticTokens_Refresh = "workspace/semanticTokens/refresh",
	.Window_ShowDocument = "window/showDocument",
	.TextDocument_LinkedEditingRange = "textDocument/linkedEditingRange",
	.Workspace_WillCreateFiles = "workspace/willCreateFiles",
	.Workspace_WillRenameFiles = "workspace/willRenameFiles",
	.Workspace_WillDeleteFiles = "workspace/willDeleteFiles",
	.TextDocument_Moniker = "textDocument/moniker",
	.TextDocument_PrepareTypeHierarchy = "textDocument/prepareTypeHierarchy",
	.TypeHierarchy_Supertypes = "typeHierarchy/supertypes",
	.TypeHierarchy_Subtypes = "typeHierarchy/subtypes",
	.TextDocument_InlineValue = "textDocument/inlineValue",
	.Workspace_InlineValue_Refresh = "workspace/inlineValue/refresh",
	.TextDocument_InlayHint = "textDocument/inlayHint",
	.InlayHint_Resolve = "inlayHint/resolve",
	.Workspace_InlayHint_Refresh = "workspace/inlayHint/refresh",
	.TextDocument_Diagnostic = "textDocument/diagnostic",
	.Workspace_Diagnostic = "workspace/diagnostic",
	.Workspace_Diagnostic_Refresh = "workspace/diagnostic/refresh",
	.TextDocument_InlineCompletion = "textDocument/inlineCompletion",
	.Client_RegisterCapability = "client/registerCapability",
	.Client_UnregisterCapability = "client/unregisterCapability",
	.Initialize = "initialize",
	.Shutdown = "shutdown",
	.Window_ShowMessageRequest = "window/showMessageRequest",
	.TextDocument_WillSaveWaitUntil = "textDocument/willSaveWaitUntil",
	.TextDocument_Completion = "textDocument/completion",
	.CompletionItem_Resolve = "completionItem/resolve",
	.TextDocument_Hover = "textDocument/hover",
	.TextDocument_SignatureHelp = "textDocument/signatureHelp",
	.TextDocument_Definition = "textDocument/definition",
	.TextDocument_References = "textDocument/references",
	.TextDocument_DocumentHighlight = "textDocument/documentHighlight",
	.TextDocument_DocumentSymbol = "textDocument/documentSymbol",
	.TextDocument_CodeAction = "textDocument/codeAction",
	.CodeAction_Resolve = "codeAction/resolve",
	.Workspace_Symbol = "workspace/symbol",
	.WorkspaceSymbol_Resolve = "workspaceSymbol/resolve",
	.TextDocument_CodeLens = "textDocument/codeLens",
	.CodeLens_Resolve = "codeLens/resolve",
	.Workspace_CodeLens_Refresh = "workspace/codeLens/refresh",
	.TextDocument_DocumentLink = "textDocument/documentLink",
	.DocumentLink_Resolve = "documentLink/resolve",
	.TextDocument_Formatting = "textDocument/formatting",
	.TextDocument_RangeFormatting = "textDocument/rangeFormatting",
	.TextDocument_RangesFormatting = "textDocument/rangesFormatting",
	.TextDocument_OnTypeFormatting = "textDocument/onTypeFormatting",
	.TextDocument_Rename = "textDocument/rename",
	.TextDocument_PrepareRename = "textDocument/prepareRename",
	.Workspace_ExecuteCommand = "workspace/executeCommand",
	.Workspace_ApplyEdit = "workspace/applyEdit",
	.Workspace_DidChangeWorkspaceFolders = "workspace/didChangeWorkspaceFolders",
	.Window_WorkDoneProgress_Cancel = "window/workDoneProgress/cancel",
	.Workspace_DidCreateFiles = "workspace/didCreateFiles",
	.Workspace_DidRenameFiles = "workspace/didRenameFiles",
	.Workspace_DidDeleteFiles = "workspace/didDeleteFiles",
	.NotebookDocument_DidOpen = "notebookDocument/didOpen",
	.NotebookDocument_DidChange = "notebookDocument/didChange",
	.NotebookDocument_DidSave = "notebookDocument/didSave",
	.NotebookDocument_DidClose = "notebookDocument/didClose",
	.Initialized = "initialized",
	.Exit = "exit",
	.Workspace_DidChangeConfiguration = "workspace/didChangeConfiguration",
	.Window_ShowMessage = "window/showMessage",
	.Window_LogMessage = "window/logMessage",
	.Telemetry_Event = "telemetry/event",
	.TextDocument_DidOpen = "textDocument/didOpen",
	.TextDocument_DidChange = "textDocument/didChange",
	.TextDocument_DidClose = "textDocument/didClose",
	.TextDocument_DidSave = "textDocument/didSave",
	.TextDocument_WillSave = "textDocument/willSave",
	.Workspace_DidChangeWatchedFiles = "workspace/didChangeWatchedFiles",
	.TextDocument_PublishDiagnostics = "textDocument/publishDiagnostics",
	.Dollar_SetTrace = "$/setTrace",
	.Dollar_LogTrace = "$/logTrace",
	.Dollar_CancelRequest = "$/cancelRequest",
	.Dollar_Progress = "$/progress",
}

message_info := [Method]Message_Info{
	.TextDocument_Implementation = { method = "textDocument/implementation", is_notification = false, params_type = typeid_of(ImplementationParams), result_type = typeid_of(Maybe(union {Definition, []DefinitionLink})) },
	.TextDocument_TypeDefinition = { method = "textDocument/typeDefinition", is_notification = false, params_type = typeid_of(TypeDefinitionParams), result_type = typeid_of(Maybe(union {Definition, []DefinitionLink})) },
	.Workspace_WorkspaceFolders = { method = "workspace/workspaceFolders", is_notification = false, params_type = nil, result_type = typeid_of(Maybe([]WorkspaceFolder)) },
	.Workspace_Configuration = { method = "workspace/configuration", is_notification = false, params_type = typeid_of(ConfigurationParams), result_type = typeid_of([]LSPAny) },
	.TextDocument_DocumentColor = { method = "textDocument/documentColor", is_notification = false, params_type = typeid_of(DocumentColorParams), result_type = typeid_of([]ColorInformation) },
	.TextDocument_ColorPresentation = { method = "textDocument/colorPresentation", is_notification = false, params_type = typeid_of(ColorPresentationParams), result_type = typeid_of([]ColorPresentation) },
	.TextDocument_FoldingRange = { method = "textDocument/foldingRange", is_notification = false, params_type = typeid_of(FoldingRangeParams), result_type = typeid_of(Maybe([]FoldingRange)) },
	.Workspace_FoldingRange_Refresh = { method = "workspace/foldingRange/refresh", is_notification = false, params_type = nil, result_type = nil },
	.TextDocument_Declaration = { method = "textDocument/declaration", is_notification = false, params_type = typeid_of(DeclarationParams), result_type = typeid_of(Maybe(union {Declaration, []DeclarationLink})) },
	.TextDocument_SelectionRange = { method = "textDocument/selectionRange", is_notification = false, params_type = typeid_of(SelectionRangeParams), result_type = typeid_of(Maybe([]SelectionRange)) },
	.Window_WorkDoneProgress_Create = { method = "window/workDoneProgress/create", is_notification = false, params_type = typeid_of(WorkDoneProgressCreateParams), result_type = nil },
	.TextDocument_PrepareCallHierarchy = { method = "textDocument/prepareCallHierarchy", is_notification = false, params_type = typeid_of(CallHierarchyPrepareParams), result_type = typeid_of(Maybe([]CallHierarchyItem)) },
	.CallHierarchy_IncomingCalls = { method = "callHierarchy/incomingCalls", is_notification = false, params_type = typeid_of(CallHierarchyIncomingCallsParams), result_type = typeid_of(Maybe([]CallHierarchyIncomingCall)) },
	.CallHierarchy_OutgoingCalls = { method = "callHierarchy/outgoingCalls", is_notification = false, params_type = typeid_of(CallHierarchyOutgoingCallsParams), result_type = typeid_of(Maybe([]CallHierarchyOutgoingCall)) },
	.TextDocument_SemanticTokens_Full = { method = "textDocument/semanticTokens/full", is_notification = false, params_type = typeid_of(SemanticTokensParams), result_type = typeid_of(Maybe(SemanticTokens)) },
	.TextDocument_SemanticTokens_Full_Delta = { method = "textDocument/semanticTokens/full/delta", is_notification = false, params_type = typeid_of(SemanticTokensDeltaParams), result_type = typeid_of(Maybe(union {SemanticTokens, SemanticTokensDelta})) },
	.TextDocument_SemanticTokens_Range = { method = "textDocument/semanticTokens/range", is_notification = false, params_type = typeid_of(SemanticTokensRangeParams), result_type = typeid_of(Maybe(SemanticTokens)) },
	.Workspace_SemanticTokens_Refresh = { method = "workspace/semanticTokens/refresh", is_notification = false, params_type = nil, result_type = nil },
	.Window_ShowDocument = { method = "window/showDocument", is_notification = false, params_type = typeid_of(ShowDocumentParams), result_type = typeid_of(ShowDocumentResult) },
	.TextDocument_LinkedEditingRange = { method = "textDocument/linkedEditingRange", is_notification = false, params_type = typeid_of(LinkedEditingRangeParams), result_type = typeid_of(Maybe(LinkedEditingRanges)) },
	.Workspace_WillCreateFiles = { method = "workspace/willCreateFiles", is_notification = false, params_type = typeid_of(CreateFilesParams), result_type = typeid_of(Maybe(WorkspaceEdit)) },
	.Workspace_WillRenameFiles = { method = "workspace/willRenameFiles", is_notification = false, params_type = typeid_of(RenameFilesParams), result_type = typeid_of(Maybe(WorkspaceEdit)) },
	.Workspace_WillDeleteFiles = { method = "workspace/willDeleteFiles", is_notification = false, params_type = typeid_of(DeleteFilesParams), result_type = typeid_of(Maybe(WorkspaceEdit)) },
	.TextDocument_Moniker = { method = "textDocument/moniker", is_notification = false, params_type = typeid_of(MonikerParams), result_type = typeid_of(Maybe([]Moniker)) },
	.TextDocument_PrepareTypeHierarchy = { method = "textDocument/prepareTypeHierarchy", is_notification = false, params_type = typeid_of(TypeHierarchyPrepareParams), result_type = typeid_of(Maybe([]TypeHierarchyItem)) },
	.TypeHierarchy_Supertypes = { method = "typeHierarchy/supertypes", is_notification = false, params_type = typeid_of(TypeHierarchySupertypesParams), result_type = typeid_of(Maybe([]TypeHierarchyItem)) },
	.TypeHierarchy_Subtypes = { method = "typeHierarchy/subtypes", is_notification = false, params_type = typeid_of(TypeHierarchySubtypesParams), result_type = typeid_of(Maybe([]TypeHierarchyItem)) },
	.TextDocument_InlineValue = { method = "textDocument/inlineValue", is_notification = false, params_type = typeid_of(InlineValueParams), result_type = typeid_of(Maybe([]InlineValue)) },
	.Workspace_InlineValue_Refresh = { method = "workspace/inlineValue/refresh", is_notification = false, params_type = nil, result_type = nil },
	.TextDocument_InlayHint = { method = "textDocument/inlayHint", is_notification = false, params_type = typeid_of(InlayHintParams), result_type = typeid_of(Maybe([]InlayHint)) },
	.InlayHint_Resolve = { method = "inlayHint/resolve", is_notification = false, params_type = typeid_of(InlayHint), result_type = typeid_of(InlayHint) },
	.Workspace_InlayHint_Refresh = { method = "workspace/inlayHint/refresh", is_notification = false, params_type = nil, result_type = nil },
	.TextDocument_Diagnostic = { method = "textDocument/diagnostic", is_notification = false, params_type = typeid_of(DocumentDiagnosticParams), result_type = typeid_of(DocumentDiagnosticReport) },
	.Workspace_Diagnostic = { method = "workspace/diagnostic", is_notification = false, params_type = typeid_of(WorkspaceDiagnosticParams), result_type = typeid_of(WorkspaceDiagnosticReport) },
	.Workspace_Diagnostic_Refresh = { method = "workspace/diagnostic/refresh", is_notification = false, params_type = nil, result_type = nil },
	.TextDocument_InlineCompletion = { method = "textDocument/inlineCompletion", is_notification = false, params_type = typeid_of(InlineCompletionParams), result_type = typeid_of(Maybe(union {InlineCompletionList, []InlineCompletionItem})) },
	.Client_RegisterCapability = { method = "client/registerCapability", is_notification = false, params_type = typeid_of(RegistrationParams), result_type = nil },
	.Client_UnregisterCapability = { method = "client/unregisterCapability", is_notification = false, params_type = typeid_of(UnregistrationParams), result_type = nil },
	.Initialize = { method = "initialize", is_notification = false, params_type = typeid_of(InitializeParams), result_type = typeid_of(InitializeResult) },
	.Shutdown = { method = "shutdown", is_notification = false, params_type = nil, result_type = nil },
	.Window_ShowMessageRequest = { method = "window/showMessageRequest", is_notification = false, params_type = typeid_of(ShowMessageRequestParams), result_type = typeid_of(Maybe(MessageActionItem)) },
	.TextDocument_WillSaveWaitUntil = { method = "textDocument/willSaveWaitUntil", is_notification = false, params_type = typeid_of(WillSaveTextDocumentParams), result_type = typeid_of(Maybe([]TextEdit)) },
	.TextDocument_Completion = { method = "textDocument/completion", is_notification = false, params_type = typeid_of(CompletionParams), result_type = typeid_of(Maybe(union {[]CompletionItem, CompletionList})) },
	.CompletionItem_Resolve = { method = "completionItem/resolve", is_notification = false, params_type = typeid_of(CompletionItem), result_type = typeid_of(CompletionItem) },
	.TextDocument_Hover = { method = "textDocument/hover", is_notification = false, params_type = typeid_of(HoverParams), result_type = typeid_of(Maybe(Hover)) },
	.TextDocument_SignatureHelp = { method = "textDocument/signatureHelp", is_notification = false, params_type = typeid_of(SignatureHelpParams), result_type = typeid_of(Maybe(SignatureHelp)) },
	.TextDocument_Definition = { method = "textDocument/definition", is_notification = false, params_type = typeid_of(DefinitionParams), result_type = typeid_of(Maybe(union {Definition, []DefinitionLink})) },
	.TextDocument_References = { method = "textDocument/references", is_notification = false, params_type = typeid_of(ReferenceParams), result_type = typeid_of(Maybe([]Location)) },
	.TextDocument_DocumentHighlight = { method = "textDocument/documentHighlight", is_notification = false, params_type = typeid_of(DocumentHighlightParams), result_type = typeid_of(Maybe([]DocumentHighlight)) },
	.TextDocument_DocumentSymbol = { method = "textDocument/documentSymbol", is_notification = false, params_type = typeid_of(DocumentSymbolParams), result_type = typeid_of(Maybe(union {[]SymbolInformation, []DocumentSymbol})) },
	.TextDocument_CodeAction = { method = "textDocument/codeAction", is_notification = false, params_type = typeid_of(CodeActionParams), result_type = typeid_of(Maybe([]union {Command, CodeAction})) },
	.CodeAction_Resolve = { method = "codeAction/resolve", is_notification = false, params_type = typeid_of(CodeAction), result_type = typeid_of(CodeAction) },
	.Workspace_Symbol = { method = "workspace/symbol", is_notification = false, params_type = typeid_of(WorkspaceSymbolParams), result_type = typeid_of(Maybe(union {[]SymbolInformation, []WorkspaceSymbol})) },
	.WorkspaceSymbol_Resolve = { method = "workspaceSymbol/resolve", is_notification = false, params_type = typeid_of(WorkspaceSymbol), result_type = typeid_of(WorkspaceSymbol) },
	.TextDocument_CodeLens = { method = "textDocument/codeLens", is_notification = false, params_type = typeid_of(CodeLensParams), result_type = typeid_of(Maybe([]CodeLens)) },
	.CodeLens_Resolve = { method = "codeLens/resolve", is_notification = false, params_type = typeid_of(CodeLens), result_type = typeid_of(CodeLens) },
	.Workspace_CodeLens_Refresh = { method = "workspace/codeLens/refresh", is_notification = false, params_type = nil, result_type = nil },
	.TextDocument_DocumentLink = { method = "textDocument/documentLink", is_notification = false, params_type = typeid_of(DocumentLinkParams), result_type = typeid_of(Maybe([]DocumentLink)) },
	.DocumentLink_Resolve = { method = "documentLink/resolve", is_notification = false, params_type = typeid_of(DocumentLink), result_type = typeid_of(DocumentLink) },
	.TextDocument_Formatting = { method = "textDocument/formatting", is_notification = false, params_type = typeid_of(DocumentFormattingParams), result_type = typeid_of(Maybe([]TextEdit)) },
	.TextDocument_RangeFormatting = { method = "textDocument/rangeFormatting", is_notification = false, params_type = typeid_of(DocumentRangeFormattingParams), result_type = typeid_of(Maybe([]TextEdit)) },
	.TextDocument_RangesFormatting = { method = "textDocument/rangesFormatting", is_notification = false, params_type = typeid_of(DocumentRangesFormattingParams), result_type = typeid_of(Maybe([]TextEdit)) },
	.TextDocument_OnTypeFormatting = { method = "textDocument/onTypeFormatting", is_notification = false, params_type = typeid_of(DocumentOnTypeFormattingParams), result_type = typeid_of(Maybe([]TextEdit)) },
	.TextDocument_Rename = { method = "textDocument/rename", is_notification = false, params_type = typeid_of(RenameParams), result_type = typeid_of(Maybe(WorkspaceEdit)) },
	.TextDocument_PrepareRename = { method = "textDocument/prepareRename", is_notification = false, params_type = typeid_of(PrepareRenameParams), result_type = typeid_of(Maybe(PrepareRenameResult)) },
	.Workspace_ExecuteCommand = { method = "workspace/executeCommand", is_notification = false, params_type = typeid_of(ExecuteCommandParams), result_type = typeid_of(Maybe(LSPAny)) },
	.Workspace_ApplyEdit = { method = "workspace/applyEdit", is_notification = false, params_type = typeid_of(ApplyWorkspaceEditParams), result_type = typeid_of(ApplyWorkspaceEditResult) },
	.Workspace_DidChangeWorkspaceFolders = { method = "workspace/didChangeWorkspaceFolders", is_notification = true, params_type = typeid_of(DidChangeWorkspaceFoldersParams), result_type = nil },
	.Window_WorkDoneProgress_Cancel = { method = "window/workDoneProgress/cancel", is_notification = true, params_type = typeid_of(WorkDoneProgressCancelParams), result_type = nil },
	.Workspace_DidCreateFiles = { method = "workspace/didCreateFiles", is_notification = true, params_type = typeid_of(CreateFilesParams), result_type = nil },
	.Workspace_DidRenameFiles = { method = "workspace/didRenameFiles", is_notification = true, params_type = typeid_of(RenameFilesParams), result_type = nil },
	.Workspace_DidDeleteFiles = { method = "workspace/didDeleteFiles", is_notification = true, params_type = typeid_of(DeleteFilesParams), result_type = nil },
	.NotebookDocument_DidOpen = { method = "notebookDocument/didOpen", is_notification = true, params_type = typeid_of(DidOpenNotebookDocumentParams), result_type = nil },
	.NotebookDocument_DidChange = { method = "notebookDocument/didChange", is_notification = true, params_type = typeid_of(DidChangeNotebookDocumentParams), result_type = nil },
	.NotebookDocument_DidSave = { method = "notebookDocument/didSave", is_notification = true, params_type = typeid_of(DidSaveNotebookDocumentParams), result_type = nil },
	.NotebookDocument_DidClose = { method = "notebookDocument/didClose", is_notification = true, params_type = typeid_of(DidCloseNotebookDocumentParams), result_type = nil },
	.Initialized = { method = "initialized", is_notification = true, params_type = typeid_of(InitializedParams), result_type = nil },
	.Exit = { method = "exit", is_notification = true, params_type = nil, result_type = nil },
	.Workspace_DidChangeConfiguration = { method = "workspace/didChangeConfiguration", is_notification = true, params_type = typeid_of(DidChangeConfigurationParams), result_type = nil },
	.Window_ShowMessage = { method = "window/showMessage", is_notification = true, params_type = typeid_of(ShowMessageParams), result_type = nil },
	.Window_LogMessage = { method = "window/logMessage", is_notification = true, params_type = typeid_of(LogMessageParams), result_type = nil },
	.Telemetry_Event = { method = "telemetry/event", is_notification = true, params_type = typeid_of(LSPAny), result_type = nil },
	.TextDocument_DidOpen = { method = "textDocument/didOpen", is_notification = true, params_type = typeid_of(DidOpenTextDocumentParams), result_type = nil },
	.TextDocument_DidChange = { method = "textDocument/didChange", is_notification = true, params_type = typeid_of(DidChangeTextDocumentParams), result_type = nil },
	.TextDocument_DidClose = { method = "textDocument/didClose", is_notification = true, params_type = typeid_of(DidCloseTextDocumentParams), result_type = nil },
	.TextDocument_DidSave = { method = "textDocument/didSave", is_notification = true, params_type = typeid_of(DidSaveTextDocumentParams), result_type = nil },
	.TextDocument_WillSave = { method = "textDocument/willSave", is_notification = true, params_type = typeid_of(WillSaveTextDocumentParams), result_type = nil },
	.Workspace_DidChangeWatchedFiles = { method = "workspace/didChangeWatchedFiles", is_notification = true, params_type = typeid_of(DidChangeWatchedFilesParams), result_type = nil },
	.TextDocument_PublishDiagnostics = { method = "textDocument/publishDiagnostics", is_notification = true, params_type = typeid_of(PublishDiagnosticsParams), result_type = nil },
	.Dollar_SetTrace = { method = "$/setTrace", is_notification = true, params_type = typeid_of(SetTraceParams), result_type = nil },
	.Dollar_LogTrace = { method = "$/logTrace", is_notification = true, params_type = typeid_of(LogTraceParams), result_type = nil },
	.Dollar_CancelRequest = { method = "$/cancelRequest", is_notification = true, params_type = typeid_of(CancelParams), result_type = nil },
	.Dollar_Progress = { method = "$/progress", is_notification = true, params_type = typeid_of(ProgressParams), result_type = nil },
}
