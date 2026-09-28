; extends

; Two roles stock nvim-treesitter has no capture for, colored by
; lua/custom/cpp_hl.lua. Priorities sit above semantic tokens (125-127 for
; type / modifier / type+modifier), or clangd's class/method tokens would paint
; straight over them.

; The return type: the `type` field of a definition, or of a declaration whose
; declarator is a function (possibly behind `*` / `&`). The whole node, so
; `std::vector<Foo>` reads as one return type -- the namespaces inside it are
; re-dimmed by the pattern below.
(function_definition
  type: (_) @type.return
  (#set! priority 128))

; One pattern per parent: `([(a) (b)] field: ...)` would make the fields
; siblings of the alternation, not its children.
(declaration
  type: (_) @type.return
  declarator: [
    (function_declarator)
    (pointer_declarator declarator: (function_declarator))
    (reference_declarator (function_declarator))
  ]
  (#set! priority 128))

(field_declaration
  type: (_) @type.return
  declarator: [
    (function_declarator)
    (pointer_declarator declarator: (function_declarator))
    (reference_declarator (function_declarator))
  ]
  (#set! priority 128))

; The name being declared or defined, as opposed to called. Anchored on
; function_declarator, so pointer/reference-returning functions match too.
(function_declarator
  declarator: [
    (identifier) @function.definition
    (field_identifier) @function.definition
    (qualified_identifier name: (identifier) @function.definition)
    (qualified_identifier name: (qualified_identifier name: (identifier) @function.definition))
  ]
  (#set! priority 128))

; Namespaces keep their color inside a return type. Lowercase only: the parser
; also calls a class qualifier (`ObjectTracksProducer::`) a namespace_identifier,
; and that one should stay a type.
((namespace_identifier) @module
  (#lua-match? @module "^[%l_]")
  (#set! priority 129))
